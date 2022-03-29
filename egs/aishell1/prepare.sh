#!/usr/bin/env bash

# author: tyriontian
# tyriontian@tencent.com

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch
stage=0        # start from 0 if you need to start from data preparation
stop_stage=100
ngpu=1         # number of gpus ("0" uses cpu, otherwise use gpu)
debugmode=1
dumpdir=dump   # directory to dump full features
N=0            # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=0      # verbose option
resume=        # Resume the training from snapshot

# feature configuration
do_delta=false

preprocess_config=conf/specaug.yaml
train_config=conf/train.yaml
lm_config=conf/lm_rnn.yaml
decode_config=conf/decode.yaml

# rnnlm related
lm_resume=         # specify a snapshot file to resume LM training
lmtag=             # tag for managing LMs

# ngram
ngramtag=
n_gram=4

# decoding parameter
recog_model=model.acc.best # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'
n_average=10

# data
data=/data/asr_data/aishell/
data_url=www.openslr.org/resources/33

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train_sp
train_dev=dev
recog_set="dev test"

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data Download"
    local/download_and_untar.sh ${data} ${data_url} data_aishell
    local/download_and_untar.sh ${data} ${data_url} resource_aishell
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 0: Data preparation"
    local/aishell_data_prep.sh ${data}/data_aishell/wav ${data}/data_aishell/transcript
    # remove space in text
    for x in train dev test; do
        cp data/${x}/text data/${x}/text_org
        paste -d " " <(cut -f 1 -d" " data/${x}/text_org) <(cut -f 2- -d" " data/${x}/text_org | tr -d " ") \
            > data/${x}/text
    done
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 30 --write_utt2num_frames true \
        data/train exp/make_fbank/train ${fbankdir}
    utils/fix_data_dir.sh data/train
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 10 --write_utt2num_frames true \
        data/dev exp/make_fbank/dev ${fbankdir}
    utils/fix_data_dir.sh data/dev
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 10 --write_utt2num_frames true \
        data/test exp/make_fbank/test ${fbankdir}
    utils/fix_data_dir.sh data/test

    # speed-perturbed
    utils/perturb_data_dir_speed.sh 0.9 data/train data/temp1
    utils/perturb_data_dir_speed.sh 1.0 data/train data/temp2
    utils/perturb_data_dir_speed.sh 1.1 data/train data/temp3
    utils/combine_data.sh --extra-files utt2uniq data/${train_set} data/temp1 data/temp2 data/temp3
    rm -r data/temp1 data/temp2 data/temp3
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 30 --write_utt2num_frames true \
        data/${train_set} exp/make_fbank/${train_set} ${fbankdir}
    utils/fix_data_dir.sh data/${train_set}

    # By tyriontian: Additionally you need to copy text_org from data/train to data_train_sp
    # text_org in this script refer the transcriptions that are segmented into word level
    # This is useful for MMI as our MMI criterion works in word level
    python3 espnet_utils/build_sp_text.py data/train/text_org | sort -k 1 > data/${train_set}/text_org

    # compute global CMVN
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

    # dump features for training
    split_dir=$(echo $PWD | awk -F "/" '{print $NF "/" $(NF-1)}')
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
    utils/create_split_dir.pl \
        /export/a{11,12,13,14}/${USER}/espnet-data/egs/${split_dir}/dump/${train_set}/delta${do_delta}/storage \
        ${feat_tr_dir}/storage
    fi
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
    utils/create_split_dir.pl \
        /export/a{11,12,13,14}/${USER}/espnet-data/egs/${split_dir}/dump/${train_dev}/delta${do_delta}/storage \
        ${feat_dt_dir}/storage
    fi
    dump.sh --cmd "$train_cmd" --nj 32 --do_delta ${do_delta} \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
        dump.sh --cmd "$train_cmd" --nj 10 --do_delta ${do_delta} \
            data/${rtask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${rtask} \
            ${feat_recog_dir}
    done
fi

dict=data/lang_1char/${train_set}_units.txt
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/

    echo "make a dictionary"
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    text2token.py -s 1 -n 1 data/${train_set}/text | cut -f 2- -d" " | tr " " "\n" \
    | sort | uniq | grep -v -e '^\s*$' | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    echo "make json files"
    data2json.sh --feat ${feat_tr_dir}/feats.scp \
                 --text-org data/${train_set}/text_org \
		 data/${train_set} ${dict} > ${feat_tr_dir}/data.json
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        data2json.sh --feat ${feat_recog_dir}/feats.scp \
                     --text-org data/${rtask}/text_org \
		     data/${rtask} ${dict} > ${feat_recog_dir}/data.json
    done
fi

# you can skip this and remove --rnnlm option in the recognition (stage 5)
if [ -z ${lmtag} ]; then
    lmtag=$(basename ${lm_config%.*})
fi
lmexpname=train_rnnlm_${backend}_${lmtag}
lmexpdir=exp/${lmexpname}
mkdir -p ${lmexpdir}

ngramexpname=train_ngram
ngramexpdir=exp/${ngramexpname}
if [ -z ${ngramtag} ]; then
    ngramtag=${n_gram}
fi
mkdir -p ${ngramexpdir}

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: LM Preparation"
    lmdatadir=data/local/lm_train
    mkdir -p ${lmdatadir}
    text2token.py -s 1 -n 1 data/train/text | cut -f 2- -d" " \
        > ${lmdatadir}/train.txt
    text2token.py -s 1 -n 1 data/${train_dev}/text | cut -f 2- -d" " \
        > ${lmdatadir}/valid.txt

    # NNLM. by default you do not need this
    ${cuda_cmd} --gpu ${ngpu} ${lmexpdir}/train.log \
        lm_train.py \
        --config ${lm_config} \
        --ngpu 1 \
        --backend ${backend} \
        --verbose 1 \
        --outdir ${lmexpdir} \
        --tensorboard-dir tensorboard/${lmexpname} \
        --train-label ${lmdatadir}/train.txt \
        --valid-label ${lmdatadir}/valid.txt \
        --resume ${lm_resume} \
        --dict ${dict}

    # prepare character-level N-gram LM. You need kenlm to run this  
    # lmplz --discount_fallback -o ${n_gram} <${lmdatadir}/train.txt > ${ngramexpdir}/${n_gram}gram.arpa
    # build_binary -s ${ngramexpdir}/${n_gram}gram.arpa ${ngramexpdir}/${n_gram}gram.bin
fi

lang=data/lang_phone
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
  local/k2_aishell_prepare_dict.sh $data/resource_aishell data/local/dict_nosp
  local/k2_prepare_lang.sh --position-dependent-phones false data/local/dict_nosp \
      "<UNK>" data/local/lang_tmp_nosp $lang || exit 1

  # We also prepare Word-level N-gram LM; order = 3, 4
  local/aishell_train_lms.sh

  for order in 3 4 ; do
      mkdir -p data/word_${order}gram
      gunzip -c data/local/lm/${order}gram-mincount/lm_unpruned.gz \
        > data/word_${order}gram/lm.arpa

      cp $lang/words.txt data/word_${order}gram/
      cp $lang/oov.int data/word_${order}gram/

      python3 -m kaldilm \
        --read-symbol-table="data/word_${order}gram/words.txt" \
        --disambig-symbol='#0' \
        --max-order=$order \
        data/word_${order}gram/lm.arpa > data/word_${order}gram/G.fst.txt
    
    done
fi

# Prepare these word N-gram LMs for SPL response
# (1) use different smooth method
# (2) use jieba rather than the ground-truth transcription
if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    # 3-gram LM with different smooth
    for sm in -wbdiscount -kndiscount -ukndiscount -ndiscount; do
        bash espnet_utils/train_lms_srilm.sh \
          --unk "<UNK>" --lm-opts $sm data/local/dict_nosp/lexicon.txt \
          data/local/train/text data/local/lm$sm  
    done

    # gtdiscount
    bash espnet_utils/train_lms_srilm.sh \
          --unk "<UNK>" data/local/dict_nosp/lexicon.txt \
          data/local/train/text data/local/lm-gtdiscount

    # word segmentation by jieba
    python3 espnet_utils/jieba_build_dict.py $lang/words.txt $lang/jieba_dict.txt
    python3 espnet_utils/text_norm.py --in-f data/train/text \
      --out-f data/local/train/text.jieba --segment
    bash espnet_utils/train_lms_srilm.sh \
      --unk "<UNK>" data/local/dict_nosp/lexicon.txt \
      data/local/train/text.jieba data/local/lm-jieba

    # build k2 directory
    for tag in wbdiscount kndiscount ukndiscount ndiscount gtdiscount jieba; do
        mkdir -p data/word_3gram_$tag; lmdir=data/word_3gram_$tag
        gunzip -c data/local/lm-$tag/srilm/srilm.o3g.kn.gz \
          > $lmdir/lm.arpa

        cp $lang/words.txt $lmdir
        cp $lang/oov.int $lmdir

        python3 -m kaldilm \
            --read-symbol-table="$lmdir/words.txt" \
            --disambig-symbol='#0' \
            --max-order=3 \
            $lmdir/lm.arpa > $lmdir/G.fst.txt

        python3 espnet/nets/scorers/word_ngram.py $lmdir
    done
    
fi
