#!/bin/bash

# Vanity Address Finder Script
# This script runs the GenerateVanityAddress script in a loop until a vanity address is found

set -e  # Exit on any error

echo "🔍 Starting vanity address search for prefix 0x40ac2e..."
echo "This script will run the Foundry script in a loop to avoid memory issues."
echo "Press Ctrl+C to stop the search."
echo ""

# Configuration
max_attempts_per_run=${MAX_ATTEMPTS_PER_RUN:-1000000}  # Default 1M attempts per run
rpc_url=${RPC_URL:-"http://localhost:8545"}  # Default to local node
log_file="vanity_search.log"

# Initialize log file
echo "Vanity Address Search Log - $(date)" > "$log_file"
echo "Searching for prefix: 0x40ac2e" >> "$log_file"
echo "Max attempts per run: $max_attempts_per_run" >> "$log_file"
echo "" >> "$log_file"

# Counter for tracking attempts
attempt_count=0
total_attempts=0

# Function to log with timestamp
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$log_file"
}

# Function to check if address was found in output
check_success() {
    local output="$1"
    if echo "$output" | grep -q "Found vanity address!"; then
        return 0
    else
        return 1
    fi
}

log "Starting search process..."

while true; do
    attempt_count=$((attempt_count + 1))
    log "=== Attempt Run #$attempt_count ==="
    log "Running forge script with max attempts: $max_attempts_per_run"
    
    # Run the forge script with limited attempts
    # Capture both stdout and stderr
    output=$(MAX_ATTEMPTS=$max_attempts_per_run forge script script/GenerateVanityAddress.s.sol:GenerateVanityPortfolioFactory --rpc-url "$rpc_url" 2>&1)
    exit_code=$?
    
    # Log the output
    echo "$output" >> "$log_file"
    
    # Check if the script found an address
    if check_success "$output"; then
        log "🎉 SUCCESS! Vanity address found!"
        log "Check the output above for the salt and address details."
        echo ""
        echo "🎉 SUCCESS! Vanity address found!"
        echo "Check the log file: $log_file"
        echo "Total runs completed: $attempt_count"
        break
    elif [ $exit_code -ne 0 ]; then
        log "❌ Script failed with exit code: $exit_code"
        log "This might be due to memory issues or other errors."
        log "Continuing with next attempt..."
    else
        log "No address found in this run. Continuing..."
    fi
    
    total_attempts=$((total_attempts + max_attempts_per_run))
    log "Total attempts so far: $total_attempts"
    
    # Optional: Add a small delay between runs to prevent overwhelming the system
    sleep 2
done

log "Vanity address search completed!"
echo "Search completed. Check $log_file for full details."
