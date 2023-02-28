#!/usr/bin/env bash
# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

fs=16000 # original 24000
n_fft=1024
n_shift=256
win_length=null

tag="mel_1024_char_lib100_vits_tts_16k_xvector"

train_set="train_clean_100"
valid_set="dev_clean"
test_sets="test_clean dev_clean test_other dev_other"

train_config=conf/tuning/train_1024_mel_vits_char.yaml
inference_config=conf/tuning/decode_vits.yaml
local_data_opts="--trim_all_silence true" # trim all silence in the audio

# export CUDA_VISIBLE_DEVICES=1

./tts.sh \
    --ngpu 2 \
    --stage 6 \
    --stop_stage 6 \
    --lang en \
    --feats_type raw \
    --fs "${fs}" \
    --n_fft "${n_fft}" \
    --n_shift "${n_shift}" \
    --win_length "${win_length}" \
    --dumpdir dump/1024_mel \
    --expdir exp/1024_mel_vits_char \
    --tts_task gan_tts \
    --use_xvector true \
    --token_type char \
    --feats_extract linear_spectrogram \
    --feats_normalize none \
    --train_config "${train_config}" \
    --train_set "${train_set}" \
    --valid_set "${valid_set}" \
    --test_sets "${test_sets}" \
    --tag "${tag}" \
    --srctexts "data/${train_set}/text" \
    --inference_model train.total_count.best.pth \
    --inference_config "${inference_config}" \
    --audio_format "wav" "$@"
    
    
    # --feats_type raw \
    # --use_xvector true \
    # --token_type char \
    # --cleaner none \
    # --tag "${tag}" \

    # --srctexts "data/${train_set}/text" \
    # --audio_format "wav" "$@"
    # --local_data_opts "${local_data_opts}" \

# reference from https://github.com/espnet/espnet/blob/master/egs2/ljspeech/tts1/conf/tuning/train_vits.yaml

# $ ./run.sh \
#     --stage 2 \
#     --ngpu 4 \
#     --fs 22050 \
#     --n_fft 1024 \
#     --n_shift 256 \
#     --win_length null \
#     --dumpdir dump/22k \
#     --expdir exp/22k \
#     --tts_task gan_tts \
#     --feats_extract linear_spectrogram \
#     --feats_normalize none \
#     --train_config ./conf/tuning/train_vits.yaml \
#     --inference_config ./conf/tuning/decode_vits.yaml
