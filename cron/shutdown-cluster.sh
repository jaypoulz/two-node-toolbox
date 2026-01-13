#!/bin/bash
# Shutdown cluster at 6pm daily
# This script changes to the deploy directory, runs make shutdown-cluster stop, then returns

set -e

LOG_FILE="$HOME/.logs/shutdown-cluster.log"
mkdir -p "$(dirname "$LOG_FILE")"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') - Starting cluster shutdown ===" >> "$LOG_FILE"

# Save current directory
ORIGINAL_DIR=$(pwd)

# Change to deploy directory
cd "$HOME/Projects/jaypoulz/two-node-toolbox/deploy" || {
    echo "ERROR: Failed to change to deploy directory" >> "$LOG_FILE"
    exit 1
}

# Run make command
if make shutdown-cluster stop >> "$LOG_FILE" 2>&1; then
    echo "SUCCESS: Cluster shutdown completed" >> "$LOG_FILE"
else
    echo "ERROR: make shutdown-cluster stop failed with exit code $?" >> "$LOG_FILE"
fi

# Return to original directory
cd "$ORIGINAL_DIR" || true

echo "=== Shutdown complete ===" >> "$LOG_FILE"
