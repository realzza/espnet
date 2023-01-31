#!/usr/bin/env bash
# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

log() {
    local fname=${BASH_SOURCE[1]##*/}
    echo -e "$(date '+%Y-%m-%dT%H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}
SECONDS=0


stage=1
stop_stage=100000
trim_all_silence=true
data_url=www.openslr.org/resources/12
train_dev="dev"

log "$0 $*"
. utils/parse_options.sh

. ./db.sh
. ./path.sh
. ./cmd.sh


if [ $# -ne 0 ]; then
    log "Error: No positional arguments are required."
    exit 2
fi

if [ -z "${LIBRISPEECH}" ]; then
    log "Fill the value of 'LIBRISPEECH' of db.sh"
    exit 1
fi

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    if [ ! -e "${LIBRISPEECH}/LibriSpeech/LICENSE.TXT" ]; then
	echo "stage 1: Data Download to ${LIBRISPEECH}"
    mkdir -p ${LIBRISPEECH}
	for part in dev-clean test-clean dev-other test-other train-clean-100; do
            local/download_and_untar.sh ${LIBRISPEECH} ${data_url} ${part}
	done
    else
        log "stage 1: ${LIBRISPEECH}/LibriSpeech/LICENSE.TXT is already existing. Skip data downloading"
    fi
fi

# if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
#     log "stage 0: local/data_prep.sh"
#     if "${trim_all_silence}"; then
#         [ ! -e data/local ] && mkdir -p data/local
#         cp ${db_root}/LibriTTS/SPEAKERS.txt data/local
#     fi
#     for name in dev-clean test-clean train-clean-100; do
#     # for name in dev-clean test-clean train-clean-100 train-clean-360; do
#         if "${trim_all_silence}"; then
#             # Remove all silence and re-create wav file
#             local/trim_all_silence.py "${db_root}/LibriTTS/${name}" data/local/${name}

#             # Copy normalized txt files while keeping the structure
#             cwd=$(pwd)
#             cd "${db_root}/LibriTTS/${name}"
#             find . -follow -name "*.normalized.txt" -print0 \
#                 | tar c --null -T - -f - | tar xf - -C "${cwd}/data/local/${name}"
#             cd "${cwd}"

#             # Create kaldi data directory with the trimed audio
#             local/data_prep.sh "data/local/${name}" "data/${name}"
#         else
#             # Create kaldi data directory with the original audio
#             local/data_prep.sh "${db_root}/LibriTTS/${name}" "data/${name}"
#         fi
#         utils/fix_data_dir.sh "data/${name}"
#     done
# fi

if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    log "stage 2: Data Preparation"
    if "${trim_all_silence}"; then
        [ ! -e data/local ] && mkdir -p data/local
        cp ${LIBRISPEECH}/LibriSpeech/SPEAKERS.TXT data/local
    fi
    for part in dev-clean test-clean dev-other test-other train-clean-100; do
        if "${trim_all_silence}"; then
            # Remove all silence and re-create wav file
            local/trim_all_silence.py "${LIBRISPEECH}/LibriSpeech/${part}" data/local/${part}

            # Copy normalized txt files while keeping the structure
            cwd=$(pwd)
            cd "${LIBRISPEECH}/LibriSpeech/${part}"
            find . -follow -name "*.normalized.txt" -print0 \
                | tar c --null -T - -f - | tar xf - -C "${cwd}/data/local/${part}"
            cd "${cwd}"

            # Create kaldi data directory with the trimed audio
            local/data_prep.sh "data/local/${part}" "data/${part}"
        # use underscore-separated names in data directories.
        else
            local/data_prep.sh ${LIBRISPEECH}/LibriSpeech/${part} data/${part//-/_}
        fi
    done
fi

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    log "stage 3: combine all training and development sets"
    utils/combine_data.sh --extra_files utt2num_frames data/${train_dev} data/dev_clean data/dev_other
fi

if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    # use external data
    if [ ! -e data/local/other_text/librispeech-lm-norm.txt.gz ]; then
	log "stage 4: prepare external text data from http://www.openslr.org/resources/11/librispeech-lm-norm.txt.gz"
        wget http://www.openslr.org/resources/11/librispeech-lm-norm.txt.gz -P data/local/other_text/
    fi
    if [ ! -e data/local/other_text/text ]; then
	# provide utterance id to each texts
	# e.g., librispeech_lng_00003686 A BANK CHECK
	zcat data/local/other_text/librispeech-lm-norm.txt.gz | \
	    awk '{ printf("librispeech_lng_%08d %s\n",NR,$0) } ' > data/local/other_text/text
    fi
fi

log "Successfully finished. [elapsed=${SECONDS}s]"
