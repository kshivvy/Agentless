#!/bin/bash

# This script launches the SWE-bench run in the background with nohup
# This allows the process to continue running even if you get logged out

# Set necessary environment variables if not already set
export MODEL="${MODEL:-gemini-2.0-flash}"
export TOPIC_ID="${TOPIC_ID:-lamda-request}"
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-lamda-response-sub}"

# Create log directory
mkdir -p logs

# Get timestamp for log files
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

echo "Starting SWE-bench run in the background..."
echo "Output will be logged to logs/swebench_${TIMESTAMP}.log"
echo "You can monitor progress using ./monitor_swebench.sh"

# Launch the process with nohup so it continues even if you log out
nohup ./run_agentless.sh > logs/swebench_${TIMESTAMP}.log 2>&1 &

# Save the process ID so you can check on it later
PID=$!
echo $PID > logs/swebench_pid.txt
echo "Process started with PID: $PID"
echo ""
echo "To check progress, run: ./monitor_swebench.sh"
echo "To view the log in real-time, run: tail -f logs/swebench_${TIMESTAMP}.log"
echo "To stop the process, run: kill \$(cat logs/swebench_pid.txt)"
