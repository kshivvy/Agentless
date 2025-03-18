#!/bin/bash

# Enable error handling
set -e  # Exit on error

# Required arguments
MODEL="${MODEL:-evergreen://blade:gdm-aip-fastpath-agent-generate-service-prod/lmroot_v3:v3_s_shared_api}"

# Pub/Sub topics
TOPIC_ID="${TOPIC_ID:-$USER-request}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$USER-response-sub}"

PARALLELISM="${PARALLELISM:-32}"
DEST_DIR="${DEST_DIR:-$USER-$(date +"%y%m%d-%H%M%S")}"
CONTEXT_WINDOW="${CONTEXT_WINDOW:-10}"
NUM_SAMPLES="${NUM_SAMPLES:-20}"
DATASET_NAME="${DATASET_NAME:-princeton-nlp/SWE-bench_Verified}"
SPLIT_NAME="${SPLIT_NAME:-test}"
TEMP_DIR="${TEMP_DIR:-/tmp}"

if [ -z "$RESULT_DIR" ]; then
    if [ -z "$1" ]; then
        RESULT_DIR="$PWD/results"
    else
        RESULT_DIR="$PWD/results/$1"
        shift
    fi
fi

CHECKPOINT_FILE="$RESULT_DIR/checkpoint.txt"
PROGRESS_LOG="$RESULT_DIR/progress.log"
CURRENT_STEP=0
# Suppress noisy gRPC INFO logging.
export GRPC_VERBOSITY=ERROR

echo MODEL=$MODEL
echo TOPIC_ID=$TOPIC_ID
echo SUBSCRIPTION_ID=$SUBSCRIPTION_ID
echo PARALLELISM=$PARALLELISM
echo NUM_SAMPLES=$NUM_SAMPLES
echo RESULT_DIR="$RESULT_DIR"
echo TEMP_DIR="$TEMP_DIR"
echo PROJECT_FILE_LOC=$PROJECT_FILE_LOC
echo DEST_DIR=$DEST_DIR
echo DATASET_NAME=$DATASET_NAME
echo SPLIT_NAME=$SPLIT_NAME

# Idempotent workspace setup.
mkdir -p $RESULT_DIR

# Function to log progress
log_progress() {
    echo "$(date): $1" | tee -a "$PROGRESS_LOG"
}

# Function to save checkpoint
save_checkpoint() {
    echo "$1" > "$CHECKPOINT_FILE"
    log_progress "Checkpoint saved: Step $1"
}

# Function to load checkpoint
load_checkpoint() {
    if [ -f "$CHECKPOINT_FILE" ]; then
        CURRENT_STEP=$(cat "$CHECKPOINT_FILE")
        log_progress "Resuming from checkpoint: Step $CURRENT_STEP"
    else
        CURRENT_STEP=0
        log_progress "No checkpoint found. Starting from the beginning."
    fi
}

run_step() {
    local step_num="$1"
    local step_desc="$2"
    shift 2;
    
    if [ "$CURRENT_STEP" -lt "$step_num" ]; then
        log_progress "Step $step_num: $step_desc"
        PYTHONPATH=$PWD "$@" && save_checkpoint "$step_num"
    else
        log_progress "Skipping Step $step_num: $step_desc (already completed)"
    fi
}

load_checkpoint

run_step 1 "Running file-level localization" \
python agentless/fl/localize.py \
    --file_level \
    --related_level \
    --fine_grain_line_level \
    --output_folder="$RESULT_DIR/location" \
    --top_n=3 \
    --compress \
    --context_window=$CONTEXT_WINDOW \
    --topic_id=$TOPIC_ID \
    --subscription_id=$SUBSCRIPTION_ID \
    --model=$MODEL \
    --parallelism=$PARALLELISM \
    --dataset_name=$DATASET_NAME \
    --split_name=$SPLIT_NAME

run_step 2 "Running repair" \
python agentless/repair/repair.py \
    --loc_file="$RESULT_DIR/location/loc_outputs.jsonl" \
    --output_folder="$RESULT_DIR/repair" \
    --temp_folder="$TEMP_DIR" \
    --loc_interval \
    --top_n=3 \
    --context_window=$CONTEXT_WINDOW \
    --max_samples=$NUM_SAMPLES \
    --cot \
    --diff_format \
    --gen_and_process \
    --topic_id=$TOPIC_ID \
    --subscription_id=$SUBSCRIPTION_ID \
    --model=$MODEL \
    --parallelism=$PARALLELISM \
    --dataset_name=$DATASET_NAME \
    --split_name=$SPLIT_NAME

run_step 3 "Perform majority voting to select the final patch" \
python agentless/repair/rerank.py \
    --patch_folder="$RESULT_DIR/repair" \
    --temp_folder="$TEMP_DIR" \
    --num_samples=$NUM_SAMPLES \
    --deduplicate \
    --plausible \
    --output_file="$RESULT_DIR/all_preds.jsonl"

run_step 4 "Uploading results to Google Cloud Storage" \
python agentless/gcs/upload_results.py \
    --source_dir="$RESULT_DIR" \
    --dest_dir="$DEST_DIR" \
    --num_workers=$PARALLELISM
