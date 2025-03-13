#!/bin/bash

# Enhanced monitoring script for Agentless SWE-bench with example-by-example tracking

clear
echo "==== Agentless SWE-bench Enhanced Progress Monitor ===="
echo ""

# Main checkpoint progress
echo "=== MAIN PROGRESS ==="
MAIN_CHECKPOINT=$(cat results/swe-bench-lite/checkpoint.txt 2>/dev/null || echo 'Initializing')
echo "Current step: $MAIN_CHECKPOINT / 15"

# Show progress bar
if [[ "$MAIN_CHECKPOINT" =~ ^[0-9]+$ ]]; then
  PROGRESS=$((MAIN_CHECKPOINT * 100 / 15))
  BARS=$((PROGRESS / 5))
  printf "Progress: [%-20s] %d%%\n" "$(printf '#%.0s' $(seq 1 $BARS))" $PROGRESS
  
  # Show current step description
  case "$MAIN_CHECKPOINT" in
    0) echo "Step: Initializing" ;;
    1) echo "Step: File-level localization" ;;
    2) echo "Step: Identifying irrelevant folders" ;;
    3) echo "Step: Running embedding-based retrieval" ;;
    4) echo "Step: Combining file locations" ;;
    5) echo "Step: Localizing to related elements" ;;
    6) echo "Step: Localizing to edit locations" ;;
    7) echo "Step: Separating edit location sets" ;;
    8) echo "Step: Generating patches" ;;
    9) echo "Step: Selecting regression tests" ;;
    10) echo "Step: Running regression tests on patches" ;;
    11) echo "Step: Generating reproduction tests" ;;
    12) echo "Step: Running reproduction tests on original repo" ;;
    13) echo "Step: Selecting reproduction tests" ;;
    14) echo "Step: Running reproduction tests on patches" ;;
    15) echo "Step: Reranking and selecting final patches" ;;
    *) echo "Step: Unknown" ;;
  esac
else
  echo "Progress: Initializing"
fi

echo ""

# Check for sub-step checkpoints
echo "=== SUB-STEP PROGRESS ==="
if [ -f "results/swe-bench-lite/patch_checkpoint.txt" ]; then
  PATCH_NUM=$(cat results/swe-bench-lite/patch_checkpoint.txt)
  echo "Patch generation: Sample $PATCH_NUM/4 in progress"
elif [[ "$MAIN_CHECKPOINT" =~ ^[0-9]+$ ]] && [ "$MAIN_CHECKPOINT" -eq "8" ]; then
  echo "Patch generation: Complete"
fi

if [ -f "results/swe-bench-lite/regression_checkpoint.txt" ]; then
  IFS=',' read -r REG_SAMPLE REG_TEST < results/swe-bench-lite/regression_checkpoint.txt
  echo "Regression tests: Sample $REG_SAMPLE, test $REG_TEST/10 in progress"
elif [[ "$MAIN_CHECKPOINT" =~ ^[0-9]+$ ]] && [ "$MAIN_CHECKPOINT" -ge "10" ]; then
  echo "Regression tests: Complete"
fi

if [ -f "results/swe-bench-lite/repro_checkpoint.txt" ]; then
  REPRO_START=$(cat results/swe-bench-lite/repro_checkpoint.txt)
  echo "Reproduction tests: Processing batch starting at $REPRO_START/40"
elif [[ "$MAIN_CHECKPOINT" =~ ^[0-9]+$ ]] && [ "$MAIN_CHECKPOINT" -ge "12" ]; then
  echo "Reproduction tests: Complete"
fi

if [ -f "results/swe-bench-lite/patch_repro_checkpoint.txt" ]; then
  IFS=',' read -r PATCH_SAMPLE PATCH_TEST < results/swe-bench-lite/patch_repro_checkpoint.txt
  echo "Patch reproduction tests: Sample $PATCH_SAMPLE, test $PATCH_TEST/10 in progress"
elif [[ "$MAIN_CHECKPOINT" =~ ^[0-9]+$ ]] && [ "$MAIN_CHECKPOINT" -ge "14" ]; then
  echo "Patch reproduction tests: Complete"
fi

echo ""

# Example-by-example progress tracking
echo "=== EXAMPLE-BY-EXAMPLE PROGRESS ==="

# Detect active example IDs being processed
ACTIVE_EXAMPLES=()

# Check the active processes for example IDs
if pgrep -f "agentless" > /dev/null; then
  # Extract example IDs from active process command lines
  for PID in $(pgrep -f "agentless"); do
    CMD=$(ps -p $PID -o args= 2>/dev/null)
    
    # Look for example IDs in command line arguments
    if [[ "$CMD" =~ ([a-zA-Z0-9_-]+__[a-zA-Z0-9_-]+-[0-9]+) ]]; then
      ACTIVE_EXAMPLES+=("${BASH_REMATCH[1]}")
    elif [[ "$CMD" =~ instance_id=\"([a-zA-Z0-9_-]+__[a-zA-Z0-9_-]+-[0-9]+)\" ]]; then
      ACTIVE_EXAMPLES+=("${BASH_REMATCH[1]}")
    fi
    
    # Check the retrieve.py process specifically - it's likely processing examples in parallel
    if [[ "$CMD" == *"retrieve.py"* ]]; then
      echo "Retrieve.py active (embedding-based retrieval in progress)"
      
      # Count processed examples by counting log files
      if [ -d "results/swe-bench-lite/retrievel_embedding/retrieval_logs" ]; then
        RET_LOG_COUNT=$(ls -1 results/swe-bench-lite/retrievel_embedding/retrieval_logs/*.log 2>/dev/null | wc -l)
        echo "  - Processed $RET_LOG_COUNT/300 examples in retrieval"
        
        # Check output file to see if results are being written
        if [ -f "results/swe-bench-lite/retrievel_embedding/retrieve_locs.jsonl" ]; then
          RET_OUT_COUNT=$(grep -c "instance_id" results/swe-bench-lite/retrievel_embedding/retrieve_locs.jsonl 2>/dev/null || echo 0)
          echo "  - Completed and written $RET_OUT_COUNT/300 examples to output file"
        else
          echo "  - Output file not yet created or empty"
        fi
      fi
    fi
  done
fi

# Look at logs for recent example IDs
if [ -d "results/swe-bench-lite" ]; then
  # Look in recent logs for example IDs
  for LOG_FILE in $(find results/swe-bench-lite -name "*.log" -type f -mmin -30 2>/dev/null); do
    for ID in $(grep -o '[a-zA-Z0-9_-]\+__[a-zA-Z0-9_-]\+-[0-9]\+' "$LOG_FILE" 2>/dev/null | sort -u); do
      ACTIVE_EXAMPLES+=("$ID")
    done
  done
fi

# Deduplicate the example IDs
if [ ${#ACTIVE_EXAMPLES[@]} -gt 0 ]; then
  printf "Currently processing examples:\n"
  printf '%s\n' "${ACTIVE_EXAMPLES[@]}" | sort -u | head -n 10
  
  # Count total examples at current stage
  echo ""
  echo "Examples progress by stage:"
  
  if [ -d "results/swe-bench-lite/file_level" ] && [ -f "results/swe-bench-lite/file_level/loc_outputs.jsonl" ]; then
    FL_COUNT=$(grep -c "instance_id" results/swe-bench-lite/file_level/loc_outputs.jsonl 2>/dev/null || echo 0)
    echo "  - File localization: $FL_COUNT examples"
  fi
  
  if [ -d "results/swe-bench-lite/related_elements" ] && [ -f "results/swe-bench-lite/related_elements/loc_outputs.jsonl" ]; then
    RE_COUNT=$(grep -c "instance_id" results/swe-bench-lite/related_elements/loc_outputs.jsonl 2>/dev/null || echo 0)
    echo "  - Related elements: $RE_COUNT examples"
  fi
  
  if [ -d "results/swe-bench-lite/edit_location_samples" ] && [ -f "results/swe-bench-lite/edit_location_samples/loc_outputs.jsonl" ]; then
    EL_COUNT=$(grep -c "instance_id" results/swe-bench-lite/edit_location_samples/loc_outputs.jsonl 2>/dev/null || echo 0)
    echo "  - Edit locations: $EL_COUNT examples"
  fi
  
  # Check repair outputs per sample
  for i in {1..4}; do
    if [ -d "results/swe-bench-lite/repair_sample_$i" ]; then
      for j in {0..9}; do
        if [ -f "results/swe-bench-lite/repair_sample_$i/output_${j}_processed.jsonl" ]; then
          REP_COUNT=$(grep -c "instance_id" "results/swe-bench-lite/repair_sample_$i/output_${j}_processed.jsonl" 2>/dev/null || echo 0)
          echo "  - Repair sample $i/$j: $REP_COUNT examples"
        fi
      done
    fi
  done
else
  echo "No example-specific activity detected in the last 30 minutes"
fi

echo ""

# Check status of the most recently modified examples
echo "=== RECENTLY MODIFIED EXAMPLES ==="
RECENT_FILES=$(find results/swe-bench-lite -name "*.jsonl" -type f -mmin -30 2>/dev/null | sort -r | head -n 5)

if [ -n "$RECENT_FILES" ]; then
  for FILE in $RECENT_FILES; do
    echo "File: $FILE"
    echo "Last modified: $(stat -c %y "$FILE")"
    echo "Examples in this file: $(grep -c "instance_id" "$FILE" 2>/dev/null || echo 0)"
    echo "Recent example IDs:"
    grep -o '"instance_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$FILE" 2>/dev/null | head -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
    echo ""
  done
else
  echo "No recently modified example files found"
fi

echo ""

# Recently completed examples by step
echo "=== RECENTLY COMPLETED EXAMPLES BY STEP ==="

# Check file-level localization
if [ -f "results/swe-bench-lite/file_level/loc_outputs.jsonl" ]; then
  echo "Recent File Localization Completions:"
  find results/swe-bench-lite/file_level -name "*.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
    sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
fi

# Check related elements
if [ -f "results/swe-bench-lite/related_elements/loc_outputs.jsonl" ]; then
  echo "Recent Related Elements Completions:"
  find results/swe-bench-lite/related_elements -name "*.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
    sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
fi

# Check edit locations
if [ -f "results/swe-bench-lite/edit_location_samples/loc_outputs.jsonl" ]; then
  echo "Recent Edit Location Completions:"
  find results/swe-bench-lite/edit_location_samples -name "*.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
    sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
fi

# Check repair samples
for i in {1..4}; do
  if [ -d "results/swe-bench-lite/repair_sample_$i" ]; then
    echo "Recent Repair Sample $i Completions:"
    find results/swe-bench-lite/repair_sample_$i -name "*processed.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
      sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
  fi
done

# Check regression test completions
if [ -d "results/swe-bench-lite/regression_tests" ]; then
  echo "Recent Regression Test Completions:"
  find results/swe-bench-lite/regression_tests -name "*.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
    sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
fi

# Check reproduction test completions
if [ -d "results/swe-bench-lite/reproduction_tests" ]; then
  echo "Recent Reproduction Test Completions:"
  find results/swe-bench-lite/reproduction_tests -name "*.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
    sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
fi

# Check reranking completions
if [ -d "results/swe-bench-lite/reranking" ]; then
  echo "Recent Reranking Completions:"
  find results/swe-bench-lite/reranking -name "*.jsonl" -type f -mmin -60 | xargs grep -h '"instance_id"' 2>/dev/null | 
    sort -u | tail -n 5 | sed 's/"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/g'
fi

echo ""

# Recent log entries
echo "=== RECENT PROGRESS LOG ==="
tail -n 10 results/swe-bench-lite/progress.log 2>/dev/null || echo "No progress log yet"
echo ""

# Running processes with CPU/Memory usage
echo "=== RUNNING PROCESSES ==="
# Check specifically for retrieve.py processes first
RETRIEVE_PROCS=$(ps -eo pid,ppid,user,%cpu,%mem,cmd --sort=-%cpu | grep -i "retrieve.py" | grep -v grep)
if [ -n "$RETRIEVE_PROCS" ]; then
  echo "$RETRIEVE_PROCS"
  echo "--- Other agentless processes: ---"
fi

# Show other Python processes
ps -eo pid,ppid,user,%cpu,%mem,cmd --sort=-%cpu | grep -i python | grep -v grep | grep -i agentless | grep -v "retrieve.py" | head -n 10
echo ""

# Show recent activity from nohup.out
echo "=== RECENT COMMAND OUTPUT ==="
if [ -f "nohup.out" ]; then
  tail -n 10 nohup.out
else
  echo "No nohup.out file found"
fi
echo ""

# Count of output files per step
echo "=== OUTPUT FILE STATISTICS ==="

# Check the retrieve.py step specifically (Step 3)
if [ -d "results/swe-bench-lite/retrievel_embedding" ]; then
  if [ -d "results/swe-bench-lite/retrievel_embedding/retrieval_logs" ]; then
    RET_LOG_COUNT=$(ls -1 results/swe-bench-lite/retrievel_embedding/retrieval_logs/*.log 2>/dev/null | wc -l)
    echo "Retrieval logs: $RET_LOG_COUNT / 300 examples processed"
  fi
  
  if [ -f "results/swe-bench-lite/retrievel_embedding/retrieve_locs.jsonl" ]; then
    RET_OUT_COUNT=$(grep -c "instance_id" results/swe-bench-lite/retrievel_embedding/retrieve_locs.jsonl 2>/dev/null || echo 0)
    RET_OUT_SIZE=$(du -h results/swe-bench-lite/retrievel_embedding/retrieve_locs.jsonl 2>/dev/null | cut -f1)
    echo "Retrieval outputs: $RET_OUT_COUNT / 300 examples written (file size: $RET_OUT_SIZE)"
  else
    echo "Retrieval outputs: file not created or empty"
  fi
fi

if [ -d "results/swe-bench-lite/file_level" ]; then
  FL_COUNT=$(find results/swe-bench-lite/file_level -name "*.jsonl" -type f | wc -l)
  echo "File-level outputs: $FL_COUNT"
fi

if [ -d "results/swe-bench-lite/related_elements" ]; then
  RE_COUNT=$(find results/swe-bench-lite/related_elements -name "*.jsonl" -type f | wc -l)
  echo "Related elements outputs: $RE_COUNT"
fi

if [ -d "results/swe-bench-lite/edit_location_samples" ]; then
  EL_COUNT=$(find results/swe-bench-lite/edit_location_samples -name "*.jsonl" -type f | wc -l)
  echo "Edit location outputs: $EL_COUNT"
fi

# Count repair outputs across all samples
if [ -d "results/swe-bench-lite/repair_sample_1" ]; then
  REP_COUNT_1=$(find results/swe-bench-lite/repair_sample_1 -name "*processed.jsonl" -type f | wc -l)
  REP_COUNT_2=$(find results/swe-bench-lite/repair_sample_2 -name "*processed.jsonl" -type f 2>/dev/null | wc -l)
  REP_COUNT_3=$(find results/swe-bench-lite/repair_sample_3 -name "*processed.jsonl" -type f 2>/dev/null | wc -l)
  REP_COUNT_4=$(find results/swe-bench-lite/repair_sample_4 -name "*processed.jsonl" -type f 2>/dev/null | wc -l)
  TOTAL_REP=$((REP_COUNT_1 + REP_COUNT_2 + REP_COUNT_3 + REP_COUNT_4))
  echo "Repair outputs: $TOTAL_REP / 40 (samples 1-4: $REP_COUNT_1, $REP_COUNT_2, $REP_COUNT_3, $REP_COUNT_4)"
fi

echo ""

# Resource usage
echo "=== SYSTEM RESOURCE USAGE ==="
echo "CPU usage:"
top -b -n 1 | grep Cpu | awk '{print $2 "% user, " $4 "% system, " $8 "% idle"}'
echo "Memory usage:"
free -h | grep Mem | awk '{print "Total: " $2 ", Used: " $3 ", Free: " $4}'
echo "Disk usage:"
df -h . | grep -v Filesystem | awk '{print "Total: " $2 ", Used: " $3 " (" $5 "), Available: " $4}'
echo ""

echo "Monitor last updated: $(date)"
echo ""
echo "For continuous monitoring, run: watch -n 30 ./monitor_swebench.sh"