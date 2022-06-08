from contextlib import contextmanager
from distutils.version import LooseVersion
import logging
from typing import Dict
from typing import List
from typing import Optional
from typing import Tuple
from typing import Union

import torch
from typeguard import check_argument_types

from espnet.nets.e2e_mt_common import ErrorCalculator as MTErrorCalculator
from espnet.nets.pytorch_backend.nets_utils import th_accuracy
from espnet.nets.pytorch_backend.transformer.add_sos_eos import add_sos_eos
from espnet.nets.pytorch_backend.transformer.label_smoothing_loss import (
    LabelSmoothingLoss,  # noqa: H301
)
from espnet2.asr.decoder.abs_decoder import AbsDecoder
from espnet2.asr.encoder.abs_encoder import AbsEncoder
from espnet2.asr.frontend.abs_frontend import AbsFrontend
from espnet2.asr.postencoder.abs_postencoder import AbsPostEncoder
from espnet2.asr.preencoder.abs_preencoder import AbsPreEncoder
from espnet2.torch_utils.device_funcs import force_gatherable
from espnet2.train.abs_espnet_model import AbsESPnetModel

if LooseVersion(torch.__version__) >= LooseVersion("1.6.0"):
    from torch.cuda.amp import autocast
else:
    # Nothing to do if torch<1.6.0
    @contextmanager
    def autocast(enabled=True):
        yield


class ESPnetNLUModel(AbsESPnetModel):
    """Encoder-Decoder model"""

    def __init__(
        self,
        vocab_size: int,
        token_list: Union[Tuple[str, ...], List[str]],
        frontend: Optional[AbsFrontend],
        preencoder: Optional[AbsPreEncoder],
        encoder: AbsEncoder,
        postencoder: Optional[AbsPostEncoder],
        decoder: AbsDecoder,
        token_decoder: Optional[torch.nn.Module],
        token_loss_weight: float = 1.0,
        src_vocab_size: int = 0,
        src_token_list: Union[Tuple[str, ...], List[str]] = [],
        ignore_id: int = -1,
        lsm_weight: float = 0.0,
        length_normalized_loss: bool = False,
        sym_space: str = "<space>",
        sym_blank: str = "<blank>",
        extract_feats_in_collect_stats: bool = True,
        share_decoder_input_output_embed: bool = False,
        share_encoder_decoder_input_embed: bool = False,
    ):
        assert check_argument_types()

        super().__init__()
        # note that eos is the same as sos (equivalent ID)
        self.sos = vocab_size - 1
        self.eos = vocab_size - 1
        self.vocab_size = vocab_size
        self.src_vocab_size = src_vocab_size
        self.ignore_id = ignore_id
        self.token_list = token_list.copy()
        self.token_loss_weight = token_loss_weight

        if share_decoder_input_output_embed:
            if decoder.output_layer is not None:
                decoder.output_layer.weight = decoder.embed[0].weight
                logging.info(
                    "Decoder input embedding and output linear layer are shared"
                )
            else:
                logging.warning(
                    "Decoder has no output layer, so it cannot be shared "
                    "with input embedding"
                )

        if share_encoder_decoder_input_embed:
            if src_vocab_size == vocab_size:
                frontend.embed[0].weight = decoder.embed[0].weight
                logging.info("Encoder and decoder input embeddings are shared")
            else:
                logging.warning(
                    f"src_vocab_size ({src_vocab_size}) does not equal tgt_vocab_size"
                    f" ({vocab_size}), so the encoder and decoder input embeddings "
                    "cannot be shared"
                )

        self.frontend = frontend
        self.preencoder = preencoder
        self.postencoder = postencoder
        self.encoder = encoder
        
        if token_loss_weight > 0.0:
            self.token_decoder = token_decoder
            self.criterion_token_nlu = LabelSmoothingLoss(
                size=vocab_size,
                padding_idx=ignore_id,
                smoothing=lsm_weight,
                normalize_length=True,
            )
        else:
            self.token_decoder = None

        if token_loss_weight < 1.0:
            self.decoder = decoder
            self.criterion_att_nlu = LabelSmoothingLoss(
                size=vocab_size,
                padding_idx=ignore_id,
                smoothing=lsm_weight,
                normalize_length=length_normalized_loss,
            )
        else:
            self.decoder = None

        # TODO(sdalmia) NLU error calculator
        self.nlu_error_calculator = None

        self.extract_feats_in_collect_stats = extract_feats_in_collect_stats

    def forward(
        self,
        text: torch.Tensor,
        text_lengths: torch.Tensor,
        src_text: torch.Tensor,
        src_text_lengths: torch.Tensor,
        **kwargs,
    ) -> Tuple[torch.Tensor, Dict[str, torch.Tensor], torch.Tensor]:
        """Frontend + Encoder + Decoder + Calc loss

        Args:
            text: (Batch, Length)
            text_lengths: (Batch,)
            src_text: (Batch, length)
            src_text_lengths: (Batch,)
            kwargs: "utt_id" is among the input.
        """
        assert text_lengths.dim() == 1, text_lengths.shape
        # Check that batch_size is unified
        assert (
            text.shape[0]
            == text_lengths.shape[0]
            == src_text.shape[0]
            == src_text_lengths.shape[0]
        ), (text.shape, text_lengths.shape, src_text.shape, src_text_lengths.shape)

        batch_size = src_text.shape[0]

        # for data-parallel
        text = text[:, : text_lengths.max()]
        src_text = src_text[:, : src_text_lengths.max()]

        if src_text_lengths.sum() / len(src_text_lengths) != src_text_lengths[0]:
            import pdb;pdb.set_trace()
        # 1. Encoder
        encoder_out, encoder_out_lens = self.encode(src_text, src_text_lengths)

        stats = dict()

        loss = 0
        # 2a. Token-decoder branch (NLU)
        if self.token_decoder is not None:
            loss_nlu_token, acc_nlu_token = self._calc_nlu_token_loss(
                encoder_out, encoder_out_lens, text, text_lengths
            )
            # Collect Token decoder branch stats
            stats["token_loss"] = loss_nlu_token.detach() if loss_nlu_token is not None else None
            stats["token_acc"] = acc_nlu_token
            loss = loss + loss_nlu_token * self.token_loss_weight

        # 2b. Attention-decoder branch (NLU)
        if self.decoder is not None:
            loss_nlu_att, acc_nlu_att = self._calc_nlu_att_loss(
                encoder_out, encoder_out_lens, text, text_lengths
            )
            # Collect Att decoder branch stats
            stats["att_loss"] = loss_nlu_att.detach() if loss_nlu_att is not None else None
            stats["att_acc"] = acc_nlu_att
            loss = loss + loss_nlu_att * (1. - self.token_loss_weight)

        # 3. Loss computation
        stats["loss"]=loss.detach()
        stats["acc"]= acc_nlu_att if self.decoder is not None else acc_nlu_token

        # force_gatherable: to-device and to-tensor if scalar for DataParallel
        loss, stats, weight = force_gatherable((loss, stats, batch_size), loss.device)
        return loss, stats, weight

    def collect_feats(
        self,
        text: torch.Tensor,
        text_lengths: torch.Tensor,
        src_text: torch.Tensor,
        src_text_lengths: torch.Tensor,
        **kwargs,
    ) -> Dict[str, torch.Tensor]:
        if self.extract_feats_in_collect_stats:
            feats, feats_lengths = self._extract_feats(src_text, src_text_lengths)
        else:
            # Generate dummy stats if extract_feats_in_collect_stats is False
            logging.warning(
                "Generating dummy stats for feats and feats_lengths, "
                "because encoder_conf.extract_feats_in_collect_stats is "
                f"{self.extract_feats_in_collect_stats}"
            )
            feats, feats_lengths = src_text, src_text_lengths
        return {"feats": feats, "feats_lengths": feats_lengths}

    def encode(
        self, src_text: torch.Tensor, src_text_lengths: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """Frontend + Encoder. Note that this method is used by nlu_inference.py

        Args:
            src_text: (Batch, Length, ...)
            src_text_lengths: (Batch, )
        """
        with autocast(False):
            # 1. Extract feats
            feats, feats_lengths = self._extract_feats(src_text, src_text_lengths)

            # 2. Data augmentation
            # if self.specaug is not None and self.training:
            #     feats, feats_lengths = self.specaug(feats, feats_lengths)

        # Pre-encoder, e.g. used for raw input data
        if self.preencoder is not None:
            feats, feats_lengths = self.preencoder(feats, feats_lengths)

        # 4. Forward encoder
        # feats: (Batch, Length, Dim)
        # -> encoder_out: (Batch, Length2, Dim2)
        encoder_out, encoder_out_lens, _ = self.encoder(feats, feats_lengths)

        # Post-encoder, e.g. NLU
        if self.postencoder is not None:
            encoder_out, encoder_out_lens = self.postencoder(
                encoder_out, encoder_out_lens
            )

        assert encoder_out.size(0) == src_text.size(0), (
            encoder_out.size(),
            src_text.size(0),
        )
        assert encoder_out.size(1) <= encoder_out_lens.max(), (
            encoder_out.size(),
            encoder_out_lens.max(),
        )

        return encoder_out, encoder_out_lens

    def _extract_feats(
        self, src_text: torch.Tensor, src_text_lengths: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        assert src_text_lengths.dim() == 1, src_text_lengths.shape

        # for data-parallel
        src_text = src_text[:, : src_text_lengths.max()]
        src_text, _ = add_sos_eos(src_text, self.sos, self.eos, self.ignore_id)
        src_text_lengths = src_text_lengths + 1

        if self.frontend is not None:
            # Frontend
            #  e.g. Embedding Lookup
            # src_text (Batch, NSamples) -> feats: (Batch, NSamples, Dim)
            feats, feats_lengths = self.frontend(src_text, src_text_lengths)
        else:
            # No frontend and no feature extract
            feats, feats_lengths = src_text, src_text_lengths
        return feats, feats_lengths

    def _calc_nlu_token_loss(
        self,
        encoder_out: torch.Tensor,
        encoder_out_lens: torch.Tensor,
        ys_pad: torch.Tensor,
        ys_pad_lens: torch.Tensor,
    ):
        ys_in_pad, ys_out_pad = add_sos_eos(ys_pad, self.sos, self.eos, self.ignore_id)
        ys_in_lens = ys_pad_lens + 1
        # 1. Forward decoder
        decoder_out = self.token_decoder(encoder_out, encoder_out_lens)

        # 2. Compute attention loss
        loss_token = self.criterion_token_nlu(decoder_out, ys_in_pad)
        acc_token = th_accuracy(
            decoder_out.view(-1, self.vocab_size),
            ys_in_pad,
            ignore_label=self.sos,
        )

        return loss_token, acc_token

    def _calc_nlu_att_loss(
        self,
        encoder_out: torch.Tensor,
        encoder_out_lens: torch.Tensor,
        ys_pad: torch.Tensor,
        ys_pad_lens: torch.Tensor,
    ):
        ys_in_pad, ys_out_pad = add_sos_eos(ys_pad, self.sos, self.eos, self.ignore_id)
        ys_in_lens = ys_pad_lens + 1

        # 1. Forward decoder
        decoder_out, _ = self.decoder(
            encoder_out, encoder_out_lens, ys_in_pad, ys_in_lens
        )

        # 2. Compute attention loss
        loss_att = self.criterion_att_nlu(decoder_out, ys_out_pad)
        acc_att = th_accuracy(
            decoder_out.view(-1, self.vocab_size),
            ys_out_pad,
            ignore_label=self.ignore_id,
        )

        return loss_att, acc_att
