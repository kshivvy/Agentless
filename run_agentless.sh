#!/bin/bash

# LaMDA CLI --kernel_id
MODEL="${MODEL:-evergreen2://blade:gdm-aip-fastpath-agent-generate-service-prod/lmroot:v3_s}"

# The dataset {verified, lite} and split {test, dev} to use.
DATASET_NAME="${DATASET_NAME:-princeton-nlp/SWE-bench_Lite}"
SPLIT_NAME="${SPLIT_NAME:-dev}"
SHARD_INDEX="${SHARD_INDEX:-0}"
NUM_SHARDS="${NUM_SHARDS:-1}"

# Pub/Sub topics
TOPIC_ID="${TOPIC_ID:-$USER-request}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$USER-response-sub}"

# Google Compute Storage arguments
DEST_DIR="${DEST_DIR:-v1p5_noemb_nodocker/$USER-$(date +"%y%m%d-%H%M%S")}"
echo GCS upload directory: $DEST_DIR

# Enable error handling
set -e  # Exit on error

# Set parallelism level - can be adjusted based on available resources
NUM_THREADS="${NUM_THREADS:-23}"
NUM_WORKERS_UPLOAD="${NUM_WORKERS_UPLOAD:-32}"

# Variables for checkpointing
RESULTS_DIR="${RESULTS_DIR:-results}"
CHECKPOINT_FILE="$RESULTS_DIR/checkpoint.txt"
PROGRESS_LOG="$RESULTS_DIR/progress.log"
CURRENT_STEP=0

SKIP_EMBEDDING="${SKIP_EMBEDDING:-true}"

# Create results directory
mkdir -p $RESULTS_DIR

# Git config is needed to run git commands during postprocessing.
git config --global user.email "johndoe@google.com"
git config --global user.name "John Doe"

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
    local step_cmd="$3"
    
    if [ "$CURRENT_STEP" -lt "$step_num" ]; then
        log_progress "Step $step_num: $step_desc"
        eval "$step_cmd"
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
run_step 1 "Running file-level localization" "
python agentless/fl/localize.py --file_level \\
                             --output_folder $RESULTS_DIR/file_level \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID \\
                             --dataset $DATASET_NAME \\
                             --split $SPLIT_NAME \\
                             --shard $SHARD_INDEX \\
                             --num_shards $NUM_SHARDS
"

upload_results_to_gcs

# Step 2: Select top N predicted files.
run_step 2 "Select top N predicted files." "
python agentless/fl/combine.py --retrieval_loc_file $RESULTS_DIR/file_level/loc_outputs.jsonl \\
                            --model_loc_file $RESULTS_DIR/file_level/loc_outputs.jsonl \\
                            --top_n 3 \\
                            --output_folder $RESULTS_DIR/file_level_combined
"

upload_results_to_gcs

# Step 3: Localize to related elements
run_step 3 "Localizing to related elements" "
python agentless/fl/localize.py --related_level \\
                             --output_folder $RESULTS_DIR/related_elements \\
                             --top_n 3 \\
                             --compress_assign \\
                             --compress \\
                             --start_file $RESULTS_DIR/file_level_combined/combined_locs.jsonl \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID \\
                             --dataset $DATASET_NAME \\
                             --split $SPLIT_NAME \\
                             --shard $SHARD_INDEX \\
                             --num_shards $NUM_SHARDS
"

upload_results_to_gcs

# Step 4: Localize to edit locations with sampling
run_step 4 "Localizing to edit locations" "
python agentless/fl/localize.py --fine_grain_line_level \\
                             --output_folder $RESULTS_DIR/edit_location_samples \\
                             --top_n 3 \\
                             --compress \\
                             --temperature 0.8 \\
                             --num_samples 4 \\
                             --start_file $RESULTS_DIR/related_elements/loc_outputs.jsonl \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID \\
                             --dataset $DATASET_NAME \\
                             --split $SPLIT_NAME \\
                             --shard $SHARD_INDEX \\
                             --num_shards $NUM_SHARDS
"

upload_results_to_gcs

# Step 5: Separate the individual sets of edit locations
run_step 5 "Separating edit location sets" "
python agentless/fl/localize.py --merge \\
                             --output_folder $RESULTS_DIR/edit_location_individual \\
                             --top_n 3 \\
                             --num_samples 4 \\
                             --start_file $RESULTS_DIR/edit_location_samples/loc_outputs.jsonl \\
                             --dataset $DATASET_NAME \\
                             --split $SPLIT_NAME \\
                             --shard $SHARD_INDEX \\
                             --num_shards $NUM_SHARDS
"

upload_results_to_gcs

# Step 6: Generate patches for each of the 4 sets of edit locations
if [ "$CURRENT_STEP" -lt 6 ]; then
    log_progress "Step 6: Generating patches (this may take a while)..."
    
    # Use a separate checkpoint for each patch sample
    PATCH_CHECKPOINT_FILE="$RESULTS_DIR/patch_checkpoint.txt"
    if [ -f "$PATCH_CHECKPOINT_FILE" ]; then
        PATCH_START=$(cat "$PATCH_CHECKPOINT_FILE")
        log_progress "Resuming patch generation from sample $PATCH_START"
    else
        PATCH_START=0
        log_progress "Starting patch generation from the beginning"
    fi
    
    for i in {0..3}; do
        if [ "$i" -ge "$PATCH_START" ]; then
            log_progress "Generating patches for sample $((i+1)) of 4..."
            python agentless/repair/repair.py --loc_file $RESULTS_DIR/edit_location_individual/loc_merged_${i}-${i}_outputs.jsonl \
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
                                           --shard $SHARD_INDEX \
                                           --num_shards $NUM_SHARDS
            # Save patch checkpoint
            echo $((i+1)) > "$PATCH_CHECKPOINT_FILE"
        else
            log_progress "Skipping patch generation for sample $((i+1)) (already completed)"
        fi
    done
    
    rm -f "$PATCH_CHECKPOINT_FILE"  # Remove patch checkpoint after completion
    save_checkpoint 6
else
    log_progress "Skipping Step 6: Generating patches (already completed)"
fi

upload_results_to_gcs

# Step 7: Rerank and select final patches.
run_step 7 "Reranking and selecting final patches" "
python agentless/repair/rerank.py --patch_folder $RESULTS_DIR/repair_sample_1/,$RESULTS_DIR/repair_sample_2/,$RESULTS_DIR/repair_sample_3/,$RESULTS_DIR/repair_sample_4/ \\
                                --num_samples 40 \\
                                --deduplicate \\
                                --output_file $RESULTS_DIR/all_preds.jsonl
"

upload_results_to_gcs

log_progress "All done! Final selected patches are in all_preds.jsonl"
