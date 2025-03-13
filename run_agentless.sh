#!/bin/bash

# Required arguments
MODEL="${MODEL}"

# Pub/Sub topics
TOPIC_ID="${TOPIC_ID:-lamda-request}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-lamda-response-sub}"

# TIMOTHY'S ORIGINAL SCRIPT, WITH SLIGHT MODIFICATIONS

# Enable error handling
set -e  # Exit on error

# Set parallelism level - can be adjusted based on available resources
NUM_THREADS="${NUM_THREADS:-64}"
NUM_WORKERS_TESTS="${NUM_WORKERS_TESTS:-32}"
NUM_WORKERS_REPAIR="${NUM_WORKERS_REPAIR:-16}"

# Variables for checkpointing
CHECKPOINT_FILE="results/swe-bench-lite/checkpoint.txt"
PROGRESS_LOG="results/swe-bench-lite/progress.log"
CURRENT_STEP=0

# Create results directory
mkdir -p results/swe-bench-lite

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

# Set up environment
log_progress "Setting up environment..."
# export PATH="/home/timothychung_google_com/miniforge3/condabin:$PATH"
# source "/home/timothychung_google_com/miniforge3/etc/profile.d/conda.sh"
source /opt/conda/etc/profile.d/conda.sh
conda activate agentless

# Set PYTHONPATH
export PYTHONPATH=$PYTHONPATH:$(pwd)

# Use local repository structures instead of cloning from GitHub
export PROJECT_FILE_LOC="$(pwd)/repo_cache/repo_structures"
log_progress "Using local repository structures from $PROJECT_FILE_LOC"

# Set the Google API key (already hardcoded in api_requests.py)
export GOOGLE_API_KEY="AIzaSyBWcPVvWoR9pUOFzeRgsuW2tG-U-ZPiSbU"
log_progress "Using the hardcoded Google API key from api_requests.py"

# Load the latest checkpoint
load_checkpoint

# Step 1: File-level localization
run_step 1 "Running file-level localization" "
python agentless/fl/localize.py --file_level \\
                             --output_folder results/swe-bench-lite/file_level \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID
"

# Step 2: Identify irrelevant folders
run_step 2 "Identifying irrelevant folders" "
python agentless/fl/localize.py --file_level \\
                             --irrelevant \\
                             --output_folder results/swe-bench-lite/file_level_irrelevant \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID
"

# Step 3: Run embedding-based retrieval
run_step 3 "Running embedding-based retrieval" "
python agentless/fl/retrieve.py --index_type simple \\
                             --filter_type given_files \\
                             --filter_file results/swe-bench-lite/file_level_irrelevant/loc_outputs.jsonl \\
                             --output_folder results/swe-bench-lite/retrievel_embedding \\
                             --persist_dir embedding/swe-bench_simple \\
                             --num_threads $NUM_THREADS
"

# Step 4: Combine LLM-predicted files with retrieved files
run_step 4 "Combining file locations" "
python agentless/fl/combine.py --retrieval_loc_file results/swe-bench-lite/retrievel_embedding/retrieve_locs.jsonl \\
                            --model_loc_file results/swe-bench-lite/file_level/loc_outputs.jsonl \\
                            --top_n 3 \\
                            --output_folder results/swe-bench-lite/file_level_combined
"

# Step 5: Localize to related elements
run_step 5 "Localizing to related elements" "
python agentless/fl/localize.py --related_level \\
                             --output_folder results/swe-bench-lite/related_elements \\
                             --top_n 3 \\
                             --compress_assign \\
                             --compress \\
                             --start_file results/swe-bench-lite/file_level_combined/combined_locs.jsonl \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID
"

# Step 6: Localize to edit locations with sampling
run_step 6 "Localizing to edit locations" "
python agentless/fl/localize.py --fine_grain_line_level \\
                             --output_folder results/swe-bench-lite/edit_location_samples \\
                             --top_n 3 \\
                             --compress \\
                             --temperature 0.8 \\
                             --num_samples 4 \\
                             --start_file results/swe-bench-lite/related_elements/loc_outputs.jsonl \\
                             --num_threads $NUM_THREADS \\
                             --skip_existing \\
                             --model $MODEL \\
                             --backend google-internal \\
                             --topic_id $TOPIC_ID \\
                             --subscription_id $SUBSCRIPTION_ID
"

# Step 7: Separate the individual sets of edit locations
run_step 7 "Separating edit location sets" "
python agentless/fl/localize.py --merge \\
                             --output_folder results/swe-bench-lite/edit_location_individual \\
                             --top_n 3 \\
                             --num_samples 4 \\
                             --start_file results/swe-bench-lite/edit_location_samples/loc_outputs.jsonl
"

# Step 8: Generate patches for each of the 4 sets of edit locations
if [ "$CURRENT_STEP" -lt 8 ]; then
    log_progress "Step 8: Generating patches (this may take a while)..."
    
    # Use a separate checkpoint for each patch sample
    PATCH_CHECKPOINT_FILE="results/swe-bench-lite/patch_checkpoint.txt"
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
            python agentless/repair/repair.py --loc_file results/swe-bench-lite/edit_location_individual/loc_merged_${i}-${i}_outputs.jsonl \
                                           --output_folder results/swe-bench-lite/repair_sample_$((i+1)) \
                                           --loc_interval \
                                           --top_n=3 \
                                           --context_window=10 \
                                           --max_samples 10 \
                                           --cot \
                                           --diff_format \
                                           --gen_and_process \
                                           --num_threads $NUM_WORKERS_REPAIR \
                                           --model $MODEL \
                                           --backend google-internal \
                                           --topic_id $TOPIC_ID \
                                           --subscription_id $SUBSCRIPTION_ID
            # Save patch checkpoint
            echo $((i+1)) > "$PATCH_CHECKPOINT_FILE"
        else
            log_progress "Skipping patch generation for sample $((i+1)) (already completed)"
        fi
    done
    
    rm -f "$PATCH_CHECKPOINT_FILE"  # Remove patch checkpoint after completion
    save_checkpoint 8
else
    log_progress "Skipping Step 8: Generating patches (already completed)"
fi

# Step 9: Run regression test selection
run_step 9 "Selecting regression tests" "
python agentless/test/run_regression_tests.py --run_id generate_regression_tests \\
                                           --output_file results/swe-bench-lite/passing_tests.jsonl

python agentless/test/select_regression_tests.py --passing_tests results/swe-bench-lite/passing_tests.jsonl \\
                                              --output_folder results/swe-bench-lite/select_regression
"

# Step 10: Run regression tests on all patches
if [ "$CURRENT_STEP" -lt 10 ]; then
    log_progress "Step 10: Running regression tests on all patches..."
    
    # Use separate checkpoint files for regression tests
    REGRESSION_CHECKPOINT_FILE="results/swe-bench-lite/regression_checkpoint.txt"
    
    # Format: sample_number,test_number
    if [ -f "$REGRESSION_CHECKPOINT_FILE" ]; then
        IFS=',' read -r SAMPLE_START TEST_START < "$REGRESSION_CHECKPOINT_FILE"
        log_progress "Resuming regression tests from sample $SAMPLE_START, test $TEST_START"
    else
        SAMPLE_START=1
        TEST_START=0
        log_progress "Starting regression tests from the beginning"
    fi
    
    for folder_num in {1..4}; do
        folder="results/swe-bench-lite/repair_sample_$folder_num"
        
        # Skip folders we've already processed
        if [ "$folder_num" -lt "$SAMPLE_START" ]; then
            log_progress "Skipping regression tests for $folder (already completed)"
            continue
        fi
        
        # Set starting test number
        local_test_start=0
        if [ "$folder_num" -eq "$SAMPLE_START" ]; then
            local_test_start=$TEST_START
        fi
        
        for num in {0..9}; do
            # Skip tests we've already processed
            if [ "$num" -lt "$local_test_start" ]; then
                log_progress "Skipping regression test $num for $folder (already completed)"
                continue
            fi
            
            run_id_prefix=$(basename $folder)
            log_progress "Running regression tests for $run_id_prefix sample $num..."
            
            python agentless/test/run_regression_tests.py --regression_tests results/swe-bench-lite/select_regression/output.jsonl \
                                                       --predictions_path="${folder}/output_${num}_processed.jsonl" \
                                                       --run_id="${run_id_prefix}_regression_${num}" --num_workers $NUM_WORKERS_TESTS
            
            # Save checkpoint after each test
            echo "$folder_num,$((num+1))" > "$REGRESSION_CHECKPOINT_FILE"
        done
    done
    
    rm -f "$REGRESSION_CHECKPOINT_FILE"  # Remove regression checkpoint after completion
    save_checkpoint 10
else
    log_progress "Skipping Step 10: Running regression tests (already completed)"
fi

# Step 11: Generate reproduction tests
run_step 11 "Generating reproduction tests" "
python agentless/test/generate_reproduction_tests.py --max_samples 40 \\
                                                  --output_folder results/swe-bench-lite/reproduction_test_samples \\
                                                  --num_threads $NUM_THREADS \\
                                                  --model $MODEL \\
                                                  --backend google-internal \\
                                                  --topic_id $TOPIC_ID \\
                                                  --subscription_id $SUBSCRIPTION_ID
"

# Step 12: Run reproduction tests on original repository
if [ "$CURRENT_STEP" -lt 12 ]; then
    log_progress "Step 12: Running reproduction tests on original repository..."
    
    # Use separate checkpoint for reproduction test batches
    REPRO_CHECKPOINT_FILE="results/swe-bench-lite/repro_checkpoint.txt"
    
    if [ -f "$REPRO_CHECKPOINT_FILE" ]; then
        REPRO_START=$(cat "$REPRO_CHECKPOINT_FILE")
        log_progress "Resuming reproduction tests from batch starting at $REPRO_START"
    else
        REPRO_START=0
        log_progress "Starting reproduction tests from the beginning"
    fi
    
    # Run in smaller batches to avoid overloading the system
    for st in $(seq $REPRO_START 4 36); do
        en=$((st + 3))
        log_progress "Processing samples ${st} to ${en}..."
        
        for num in $(seq $st $en); do
            log_progress "Processing sample ${num}..."
            python agentless/test/run_reproduction_tests.py --run_id="reproduction_test_generation_filter_sample_${num}" \
                                                         --test_jsonl="results/swe-bench-lite/reproduction_test_samples/output_${num}_processed_reproduction_test.jsonl" \
                                                         --num_workers $NUM_WORKERS_TESTS \
                                                         --testing
        done
        
        # Save checkpoint after each batch
        echo $((st+4)) > "$REPRO_CHECKPOINT_FILE"
    done
    
    rm -f "$REPRO_CHECKPOINT_FILE"  # Remove reproduction test checkpoint after completion
    save_checkpoint 12
else
    log_progress "Skipping Step 12: Running reproduction tests on original repository (already completed)"
fi

# Step 13: Select reproduction test via majority voting
run_step 13 "Selecting reproduction tests" "
python agentless/test/generate_reproduction_tests.py --max_samples 40 \\
                                                  --output_folder results/swe-bench-lite/reproduction_test_samples \\
                                                  --output_file reproduction_tests.jsonl \\
                                                  --select \\
                                                  --model $MODEL \\
                                                  --backend google-internal \\
                                                  --topic_id $TOPIC_ID \\
                                                  --subscription_id $SUBSCRIPTION_ID
"

# Step 14: Run reproduction tests on all patches
if [ "$CURRENT_STEP" -lt 14 ]; then
    log_progress "Step 14: Running reproduction tests on all patches..."
    
    # Use separate checkpoint files for patch reproduction tests
    PATCH_REPRO_CHECKPOINT_FILE="results/swe-bench-lite/patch_repro_checkpoint.txt"
    
    # Format: sample_number,test_number
    if [ -f "$PATCH_REPRO_CHECKPOINT_FILE" ]; then
        IFS=',' read -r SAMPLE_START TEST_START < "$PATCH_REPRO_CHECKPOINT_FILE"
        log_progress "Resuming patch reproduction tests from sample $SAMPLE_START, test $TEST_START"
    else
        SAMPLE_START=1
        TEST_START=0
        log_progress "Starting patch reproduction tests from the beginning"
    fi
    
    for folder_num in {1..4}; do
        folder="results/swe-bench-lite/repair_sample_$folder_num"
        
        # Skip folders we've already processed
        if [ "$folder_num" -lt "$SAMPLE_START" ]; then
            log_progress "Skipping patch reproduction tests for $folder (already completed)"
            continue
        fi
        
        # Set starting test number
        local_test_start=0
        if [ "$folder_num" -eq "$SAMPLE_START" ]; then
            local_test_start=$TEST_START
        fi
        
        for num in {0..9}; do
            # Skip tests we've already processed
            if [ "$num" -lt "$local_test_start" ]; then
                log_progress "Skipping patch reproduction test $num for $folder (already completed)"
                continue
            fi
            
            run_id_prefix=$(basename $folder)
            log_progress "Running reproduction tests for $run_id_prefix sample $num..."
            
            python agentless/test/run_reproduction_tests.py --test_jsonl results/swe-bench-lite/reproduction_test_samples/reproduction_tests.jsonl \
                                                         --predictions_path="${folder}/output_${num}_processed.jsonl" \
                                                         --run_id="${run_id_prefix}_reproduction_${num}" --num_workers $NUM_WORKERS_TESTS
            
            # Save checkpoint after each test
            echo "$folder_num,$((num+1))" > "$PATCH_REPRO_CHECKPOINT_FILE"
        done
    done
    
    rm -f "$PATCH_REPRO_CHECKPOINT_FILE"  # Remove patch reproduction checkpoint after completion
    save_checkpoint 14
else
    log_progress "Skipping Step 14: Running reproduction tests on all patches (already completed)"
fi

# Step 15: Rerank and select final patches
run_step 15 "Reranking and selecting final patches" "
python agentless/repair/rerank.py --patch_folder results/swe-bench-lite/repair_sample_1/,results/swe-bench-lite/repair_sample_2/,results/swe-bench-lite/repair_sample_3/,results/swe-bench-lite/repair_sample_4/ \\
                                --num_samples 40 \\
                                --deduplicate \\
                                --regression \\
                                --reproduction
"

log_progress "All done! Final selected patches are in all_preds.jsonl"

# Cleanup checkpoint file after successful completion
