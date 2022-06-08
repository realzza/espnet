#!/usr/bin/env bash
# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set="train"
valid_set="devel"
test_sets="test devel"

asr_config=conf/tuning/train_asr_conformer_yifan_specaug_change.yaml
inference_config=conf/decode_asr.yaml

./asr.sh \
    --lang en \
    --ngpu 1 \
    --use_lm false \
    --stage 13\
    --stop_stage 13\
    --gpu_inference true\
    --nbpe 5000 \
    --token_type word\
    --feats_type raw\
    --audio_format "flac.ark" \
    --max_wav_duration 30 \
    --feats_normalize utterance_mvn\
    --nj 32 \
    --inference_nj 32 \
    --inference_asr_model valid.acc.ave_10best.pth\
    --asr_config "${asr_config}" \
    --inference_config "${inference_config}" \
    --train_set "${train_set}" \
    --valid_set "${valid_set}" \
    --test_sets "${test_sets}" "$@"
