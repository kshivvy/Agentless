#!/bin/bash

# Enable error handling
set -e  # Exit on error

# Required arguments
MODEL="${MODEL:-evergreen://blade:gdm-aip-fastpath-agent-generate-service-prod/lmroot_v3:v3_s_shared_api}"

# Pub/Sub topics
TOPIC_ID="${TOPIC_ID:-jjong-request}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-jjong-response-sub}"

PARALLELISM="${PARALLELISM:-32}"
CONTEXT_WINDOW=10
REPAIR_SAMPLES=10

if [ -z "$1" ]; then
    RESULT_DIR="$PWD/results"
else
    RESULT_DIR="$PWD/results/$1"
    shift
fi

CHECKPOINT_FILE="$RESULT_DIR/checkpoint.txt"
PROGRESS_LOG="$RESULT_DIR/progress.log"
CURRENT_STEP=0

echo MODEL=$MODEL
echo TOPIC_ID=$TOPIC_ID
echo SUBSCRIPTION_ID=$SUBSCRIPTION_ID
echo NUM_THREAD=$PARALLELISM
echo RESULT_DIR="$RESULT_DIR"
echo PROJECT_FILE_LOC=$PROJECT_FILE_LOC

# Idempotent workspace setup.
mkdir -p $RESULT_DIR
export PROJECT_FILE_LOC=/Users/jjong/data/swebench_lite_repo_structure

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
    --parallelism=$PARALLELISM

run_step 2 "Running repair" \
python agentless/repair/repair.py \
    --loc_file="$RESULT_DIR/location/loc_outputs.jsonl" \
    --output_folder="$RESULT_DIR/repair" \
    --loc_interval \
    --top_n=3 \
    --context_window=$CONTEXT_WINDOW \
    --max_samples=$REPAIR_SAMPLES \
    --cot \
    --diff_format \
    --gen_and_process \
    --topic_id=$TOPIC_ID \
    --subscription_id=$SUBSCRIPTION_ID \
    --model=$MODEL \
    --parallelism=$PARALLELISM \

run_step 3 "Perform majority voting to select the final patch" \
python agentless/repair/rerank.py \
    --patch_folder="$RESULT_DIR/repair" \
    --num_samples=$REPAIR_SAMPLES \
    --deduplicate \
    --plausible

run_step 4 "Uploading results to Google Cloud Storage" \
python agentless/gcs/upload_results.py \
--source_dir results \
--dest_dir $DEST_DIR \
--num_workers $PARALLELISM
