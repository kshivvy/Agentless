#!/bin/bash

# LaMDA CLI --kernel_id
MODEL="${MODEL:-evergreen2:///mbns/vz/home/courier/mvuyyuru/rev18p1_v3p1m}"

# The dataset {verified, lite} and split {test, dev} to use.
DATASET_NAME="${DATASET_NAME:-princeton-nlp/SWE-bench_Lite}"
SPLIT_NAME="${SPLIT_NAME:-dev}"
SHARD_INDEX="${SHARD_INDEX:-${CLOUD_RUN_TASK_INDEX:-0}}"
NUM_SHARDS="${NUM_SHARDS:-${CLOUD_RUN_TASK_COUNT:-23}}"

# Pub/Sub topics
TOPIC_ID="${TOPIC_ID:-$USER-req}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$USER-resp-sub}"
if [[ "$CLOUD_RUN_TASK_COUNT" -gt 1 ]]; then
  SUBSCRIPTION_ID="${SUBSCRIPTION_ID}${SHARD_INDEX}"
fi

# Google Compute Storage arguments
DEST_DIR="${DEST_DIR:-v1p5_noemb_nodocker/$USER-$(date +"%y%m%d-%H%M%S")}"
if [[ "$CLOUD_RUN_TASK_COUNT" -gt 1 ]]; then
  DEST_DIR="${DEST_DIR%/}/shard-$(printf "%02d" $CLOUD_RUN_TASK_INDEX)"
fi
echo GCS upload directory: $DEST_DIR

# Enable error handling
set -e  # Exit on error

# Set parallelism level - can be adjusted based on available resources
NUM_THREADS="${NUM_THREADS:-32}"
NUM_WORKERS_UPLOAD="${NUM_WORKERS_UPLOAD:-32}"

# Variables for checkpointing
RESULTS_DIR="${RESULTS_DIR:-results/$(date +"%m/%d")}"
CHECKPOINT_FILE="$RESULTS_DIR/checkpoint.txt"
PROGRESS_LOG="$RESULTS_DIR/progress.log"
CURRENT_STEP=0

SKIP_EMBEDDING="${SKIP_EMBEDDING:-true}"

# Create results directory
mkdir -p $RESULTS_DIR

# Set gRPC verbosity level to ERROR to silence unnecessary logs
# about skipping fork() handlers due to other threads calling into gRPC.
export GRPC_VERBOSITY=ERROR

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

# Function to run a step with checkpointing
run_step() {
    local step_num="$1"
    local step_desc="$2"
    shift 2;

    if [ "$CURRENT_STEP" -lt "$step_num" ]; then
        log_progress "Step $step_num: $step_desc"
        "$@"
        save_checkpoint "$step_num"
    else
        log_progress "Skipping Step $step_num: $step_desc (already completed)"
    fi
}

# Function to upload results to Google Cloud Storage
upload_results_to_gcs() {
    log_progress "Uploading results to Google Cloud Storage..."
    python agentless/gcs/upload_results.py --source_dir $RESULTS_DIR \
                                          --dest_dir $DEST_DIR \
                                          --num_workers $NUM_WORKERS_UPLOAD
}

# Set PYTHONPATH
export PYTHONPATH=$PYTHONPATH:$(pwd)

# Set the OPENAI_API_KEY
export OPENAI_API_KEY=$OPEN_AI_KEY

# Use local repository structures instead of cloning from GitHub
PROJECT_FILE_LOC="${PROJECT_FILE_LOC:-$(pwd)/repo_structures}"
export PROJECT_FILE_LOC

# Set the Google API key (already hardcoded in api_requests.py)
export GOOGLE_API_KEY="AIzaSyBWcPVvWoR9pUOFzeRgsuW2tG-U-ZPiSbU"
log_progress "Using the hardcoded Google API key from api_requests.py"

# Load the latest checkpoint
load_checkpoint

# Step 1: File-level localization
run_step 1 "Running file-level localization" \
python agentless/fl/localize.py --file_level \
                             --output_folder $RESULTS_DIR/file_level \
                             --num_threads $NUM_THREADS \
                             --skip_existing \
                             --model $MODEL \
                             --backend google-internal \
                             --topic_id $TOPIC_ID \
                             --subscription_id $SUBSCRIPTION_ID \
                             --dataset $DATASET_NAME \
                             --split $SPLIT_NAME \
                             --shard_index $SHARD_INDEX \
                             --num_shards $NUM_SHARDS


upload_results_to_gcs

# Step 2: Select top N predicted files.
run_step 2 "Select top N predicted files." \
python agentless/fl/combine.py --retrieval_loc_file $RESULTS_DIR/file_level/loc_outputs.jsonl \
                            --model_loc_file $RESULTS_DIR/file_level/loc_outputs.jsonl \
                            --top_n 3 \
                            --output_folder $RESULTS_DIR/file_level_combined


upload_results_to_gcs

# Step 3: Localize to related elements
run_step 3 "Localizing to related elements" \
python agentless/fl/localize.py --related_level \
                             --output_folder $RESULTS_DIR/related_elements \
                             --top_n 3 \
                             --compress_assign \
                             --compress \
                             --start_file $RESULTS_DIR/file_level_combined/combined_locs.jsonl \
                             --num_threads $NUM_THREADS \
                             --skip_existing \
                             --model $MODEL \
                             --backend google-internal \
                             --topic_id $TOPIC_ID \
                             --subscription_id $SUBSCRIPTION_ID \
                             --dataset $DATASET_NAME \
                             --split $SPLIT_NAME \
                             --shard_index $SHARD_INDEX \
                             --num_shards $NUM_SHARDS


upload_results_to_gcs

# Step 4: Localize to edit locations with sampling
run_step 4 "Localizing to edit locations" \
python agentless/fl/localize.py --fine_grain_line_level \
                             --output_folder $RESULTS_DIR/edit_location_samples \
                             --top_n 3 \
                             --compress \
                             --temperature 0.8 \
                             --num_samples 4 \
                             --start_file $RESULTS_DIR/related_elements/loc_outputs.jsonl \
                             --num_threads $NUM_THREADS \
                             --skip_existing \
                             --model $MODEL \
                             --backend google-internal \
                             --topic_id $TOPIC_ID \
                             --subscription_id $SUBSCRIPTION_ID \
                             --dataset $DATASET_NAME \
                             --split $SPLIT_NAME \
                             --shard_index $SHARD_INDEX \
                             --num_shards $NUM_SHARDS


upload_results_to_gcs

# Step 5: Separate the individual sets of edit locations
run_step 5 "Separating edit location sets" \
python agentless/fl/localize.py --merge \
                             --output_folder $RESULTS_DIR/edit_location_individual \
                             --top_n 3 \
                             --num_samples 4 \
                             --start_file $RESULTS_DIR/edit_location_samples/loc_outputs.jsonl \
                             --dataset $DATASET_NAME \
                             --split $SPLIT_NAME \
                             --shard_index $SHARD_INDEX \
                             --num_shards $NUM_SHARDS


upload_results_to_gcs

# Step 6: Generate patches for each of the 4 sets of edit locations
if [ "$CURRENT_STEP" -lt 6 ]; then
    log_progress "Step 6: Generating patches (this may take a while)..."

    # --- Start Parallel Execution ---
    # NOTE: Running 4 instances in parallel. Each instance uses NUM_THREADS.
    # Ensure NUM_THREADS is set appropriately to avoid overloading the system.
    # Total threads used will be approximately 4 * NUM_THREADS. Consider reducing NUM_THREADS.

    for i in {0..3}; do
        log_progress "Generating patches for sample $((i+1)) of 4..."
        python agentless/repair/repair.py  --loc_file $RESULTS_DIR/edit_location_individual/loc_merged_${i}-${i}_outputs.jsonl \
                                           --output_folder $RESULTS_DIR/repair_sample_$((i+1)) \
                                           --loc_interval \
                                           --top_n=3 \
                                           --context_window=10 \
                                           --max_samples 10 \
                                           --cot \
                                           --diff_format \
                                           --gen_and_process \
                                           --num_threads $NUM_THREADS \
                                           --model $MODEL \
                                           --backend google-internal \
                                           --topic_id $TOPIC_ID \
                                           --subscription_id $SUBSCRIPTION_ID \
                                           --dataset $DATASET_NAME \
                                           --split $SPLIT_NAME \
                                           --shard_index $SHARD_INDEX \
                                           --num_shards $NUM_SHARDS \
                                           --session_id $((i+1)) & # <-- Run in background
    done

    # Wait for all background jobs launched in the loop to complete
    log_progress "Waiting for all parallel patch generation jobs to complete..."
    wait
    log_progress "Parallel patch generation completed."
    # --- End Parallel Execution ---

    # Save the main checkpoint *after* all parallel jobs are finished
    save_checkpoint 6
else
    log_progress "Skipping Step 6: Generating patches (already completed)"
fi

upload_results_to_gcs

# Step 7: Rerank and select final patches.
run_step 7 "Reranking and selecting final patches" \
python agentless/repair/rerank.py --patch_folder $RESULTS_DIR/repair_sample_1/,$RESULTS_DIR/repair_sample_2/,$RESULTS_DIR/repair_sample_3/,$RESULTS_DIR/repair_sample_4/ \
                                --num_samples 40 \
                                --deduplicate \
                                --output_file $RESULTS_DIR/all_preds.jsonl


upload_results_to_gcs

log_progress "All done! Final selected patches are in all_preds.jsonl"
