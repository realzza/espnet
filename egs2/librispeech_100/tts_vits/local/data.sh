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
data_url=www.openslr.org/resources/12
train_dev="dev"
trim_all_silence=false

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
    if [ ! -e "${LIBRISPEECH}/LibriSpeech/.download_complete" ]; then
        echo "stage 1: Data Download to ${LIBRISPEECH}"
        mkdir -p ${LIBRISPEECH}
        for part in dev-clean test-clean dev-other test-other train-clean-100 train-clean-360; do
                local/download_and_untar.sh ${LIBRISPEECH} ${data_url} ${part}
        done
        touch "${LIBRISPEECH}/LibriSpeech/.download_complete"
    else
        log "stage 1: ${LIBRISPEECH}/LibriSpeech/.download_complete is already existing. Skip data downloading"
    fi
fi

# TODO: add trim_all_silence here
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    log "stage 2: Data Preparation"
    if "${trim_all_silence}"; then
        [ ! -e data/local ] && mkdir -p data/local
        cp ${LIBRISPEECH}/LibriSpeech/SPEAKERS.TXT data/local
    fi
    for part in dev-clean test-clean dev-other test-other train-clean-100 train-clean-360; do
        if "${trim_all_silence}"; then
            if [ ! -e data/local/${part} ]; then
                mkdir -p data/local/${part}
            fi
            # remove all silence and re-create wav files
            local/trim_all_silence.py "${LIBRISPEECH}/LibriSpeech/${part}" data/local/${part}

            # copy normalized txt files while keep structure
            # FIXME: -name here is a flag or a param
            cwd=$(pwd)
            cd "${LIBRISPEECH}/LibriSpeech/${part}"
            find . -follow -name "*.normalized.txt" -print0 \
                | tar c --null -T - -f - | tar xf - -C "${cwd}/data/local/${part}"
            cd "${cwd}"

            # create kaldi data directory with trimmed audio
            local/data_prep.sh "data/local/${part}" "data/${part//-/_}"
        else
            # use underscore-separated names in data directories.
            local/data_prep.sh ${LIBRISPEECH}/LibriSpeech/${part} data/${part//-/_}
        fi
        # FIXME: ADD OR NOT utils/fix_data_dir.sh "data/${name}"
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
