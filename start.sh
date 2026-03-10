#!/bin/bash

# Ralph Start - Main execution loop with tmux support
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/response_analyzer.sh"

# Configuration
CLAUDE_CMD="claude --dangerously-skip-permissions"

# Use gtimeout on macOS (from brew install coreutils), timeout on Linux
if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
else
    echo "ERROR: 'timeout' command not found. Install with: brew install coreutils"
    exit 1
fi
MAX_CALLS_PER_HOUR=${MAX_CALLS_PER_HOUR:-100}
CLAUDE_TIMEOUT_MINUTES=${CLAUDE_TIMEOUT_MINUTES:-20}
MAX_ITERATIONS=${MAX_ITERATIONS:-0}  # 0 = unlimited
COMPLETE_TOKEN=${COMPLETE_TOKEN:-"<promise>COMPLETE</promise>"}
USE_TMUX=false

# Rate limiting files
CALL_COUNT_FILE=".call_count"
TIMESTAMP_FILE=".last_reset"

show_help() {
    cat << HELPEOF
Ralph Start - Run the autonomous development loop

Usage: $0 <project-name> [OPTIONS]

Arguments:
    project-name    Name of the Ralph project to run

Options:
    -m, --monitor           Start with tmux session and live monitor
    -n, --max-iterations N  Max loop iterations (default: 0 = unlimited)
    -c, --calls NUM         Max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -t, --timeout MIN       Claude timeout in minutes (default: $CLAUDE_TIMEOUT_MINUTES)
    --complete-token STR    Token that signals project completion
                            (default: $COMPLETE_TOKEN)
    -s, --status            Show project status and exit
    -r, --reset             Reset circuit breaker and continue
    -h, --help              Show this help

Examples:
    $0 signals                    # Run unlimited until complete
    $0 signals --monitor          # Run with tmux monitoring
    $0 signals -n 5               # Run max 5 iterations
    $0 signals -n 10 --monitor    # 10 iterations with monitoring
    $0 signals --status           # Show current status
    $0 signals --reset            # Reset circuit breaker

Environment Variables:
    MAX_ITERATIONS          Override max iterations
    MAX_CALLS_PER_HOUR      Override rate limit
    CLAUDE_TIMEOUT_MINUTES  Override Claude timeout
    COMPLETE_TOKEN          Override completion token

HELPEOF
}

# Initialize rate limiting
init_rate_limiting() {
    local project_dir=$1
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""
    
    local count_file="$project_dir/$CALL_COUNT_FILE"
    local ts_file="$project_dir/$TIMESTAMP_FILE"
    
    if [[ -f "$ts_file" ]]; then
        last_reset_hour=$(cat "$ts_file")
    fi
    
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$count_file"
        echo "$current_hour" > "$ts_file"
        log "INFO" "Rate limit counter reset for new hour"
    fi
}

# Check if we can make another call
can_make_call() {
    local project_dir=$1
    local count_file="$project_dir/$CALL_COUNT_FILE"
    local calls_made=0
    
    if [[ -f "$count_file" ]]; then
        calls_made=$(cat "$count_file")
    fi
    
    [[ $calls_made -lt $MAX_CALLS_PER_HOUR ]]
}

# Increment call counter
increment_call_counter() {
    local project_dir=$1
    local count_file="$project_dir/$CALL_COUNT_FILE"
    local calls_made=0
    
    if [[ -f "$count_file" ]]; then
        calls_made=$(cat "$count_file")
    fi
    
    calls_made=$((calls_made + 1))
    echo "$calls_made" > "$count_file"
    echo "$calls_made"
}

# Wait for rate limit reset
wait_for_reset() {
    local project_dir=$1
    local calls_made=$(cat "$project_dir/$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    
    log "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    local wait_time=$(get_seconds_until_next_hour)
    log "INFO" "Sleeping for $(format_duration $wait_time) until next hour..."
    
    while [[ $wait_time -gt 0 ]]; do
        printf "\r${YELLOW}Time until reset: $(format_duration $wait_time)${NC}"
        sleep 1
        wait_time=$((wait_time - 1))
    done
    printf "\n"
    
    echo "0" > "$project_dir/$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$project_dir/$TIMESTAMP_FILE"
    log "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Update status file
update_status() {
    local project_dir=$1
    local loop_count=$2
    local status=$3
    local current_story=${4:-""}
    
    local prd_file="$project_dir/prd.json"
    local complete=$(count_complete_stories "$prd_file")
    local total=$(count_total_stories "$prd_file")
    local calls=$(cat "$project_dir/$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    
    cat > "$project_dir/status.json" << EOF
{
    "timestamp": "$(get_iso_timestamp)",
    "status": "$status",
    "loop_count": $loop_count,
    "current_story": "$current_story",
    "stories_complete": $complete,
    "stories_total": $total,
    "calls_this_hour": $calls,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR
}
EOF
}

# Generate the FULL prompt with ALL stories (like original ralph.sh)
generate_full_prompt() {
    local project_dir=$1
    
    local prompt_template=$(cat "$project_dir/PROMPT.md")
    local prd_content=$(cat "$project_dir/prd.json")
    local progress_content=$(cat "$project_dir/progress.txt" 2>/dev/null || echo "No progress yet.")
    local requirements_content=$(cat "$project_dir/requirements.md" 2>/dev/null || echo "No requirements yet.")
    
    # Count stories
    local complete=$(count_complete_stories "$project_dir/prd.json")
    local total=$(count_total_stories "$project_dir/prd.json")
    local incomplete=$((total - complete))
    
    # Get branch name if available
    local branch_name=$(get_branch_name "$project_dir/prd.json")
    local branch_info=""
    local branch_warning=""
    if [[ -n "$branch_name" ]]; then
        branch_info="**Branch:** \`$branch_name\`"
        branch_warning="
## ⛔ BRANCH RESTRICTION ⛔

**You are ONLY allowed to push to branch: \`$branch_name\`**
- DO NOT switch to any other branch, do not create new branches.
- DO NOT push to main, master, or any branch other than \`$branch_name\`
"
    fi


cat << EOF
$prompt_template

---

## Project Files

| File | Description |
|------|-------------|
| @ralph/projects/$project_name/prd.md | Full PRD with context |
| @ralph/projects/$project_name/prd.json | User stories (\`passes: false\` = incomplete) |
| @ralph/projects/$project_name/progress.txt | What previous iterations accomplished |
| @ralph/projects/$project_name/requirements.md | Technical requirements |

$branch_info
**Progress: $complete/$total complete ($incomplete remaining)**
$branch_warning

## Completion Token

When ALL user stories have \`passes: true\`, reply with:
$COMPLETE_TOKEN

---

Now, follow the instructions above and implement the next incomplete story (lowest priority number that has \`passes: false\`). STOP after completing ONE story.
EOF
}






# Execute Claude Code with FULL context
# Returns: 0=success, 1=error, 2=project complete, 3=API limit, 4=timeout (after retries exhausted), 5=usage limit (with reset time)
execute_claude() {
    local project_dir=$1
    local loop_count=$2
    
    local max_timeout_retries=2  # Retry up to 2 more times on timeout (3 total attempts)
    local timeout_attempt=0
    
    log "LOOP" "Executing Claude Code (Loop #$loop_count)"
    
    # Generate prompt (not saved to disk)
    local prompt_content
    prompt_content=$(generate_full_prompt "$project_dir")
    
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    
    # Change to repo root for Claude
    cd "$REPO_ROOT"
    
    # Retry loop for timeout handling
    while true; do
        timeout_attempt=$((timeout_attempt + 1))
        
        local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
        local output_file="$project_dir/logs/claude_${timestamp}.log"
        
        if [[ $timeout_attempt -gt 1 ]]; then
            log "INFO" "⏳ Timeout retry $((timeout_attempt - 1))/$max_timeout_retries (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)..."
        else
            log "INFO" "⏳ Starting Claude (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)..."
        fi
        
        # Execute Claude
        if echo "$prompt_content" | $TIMEOUT_CMD ${timeout_seconds}s $CLAUDE_CMD > "$output_file" 2>&1; then
            log "SUCCESS" "✅ Claude execution completed"
            
            # Check for project completion token
            if grep -q "$COMPLETE_TOKEN" "$output_file"; then
                log "SUCCESS" "🎉 Claude signaled PROJECT COMPLETE!"
                return 2  # Special code for project complete
            fi
            
            # Analyze response
            analyze_response "$output_file" "$project_dir"
            local analysis_result=$?
            
            # Get analysis details
            local files_modified=$(get_analysis_result "$project_dir" "files_modified")
            local has_errors=$(get_analysis_result "$project_dir" "has_errors")
            local error_message=$(get_analysis_result "$project_dir" "error_message")
            local exit_signal=$(get_analysis_result "$project_dir" "exit_signal")
            local output_length=$(wc -c < "$output_file")
            
            # Record in circuit breaker
            record_loop_result "$project_dir" "$loop_count" "${files_modified:-0}" "$has_errors" "$output_length" "$error_message"
            
            # Log analysis
            log_analysis_summary "$project_dir"
            
            # Claude updates prd.json directly - no need to mark stories here
            # Just log completion status for visibility
            if [[ "$exit_signal" == "true" ]]; then
                log "SUCCESS" "📝 Claude signaled loop completion"
            fi
            
            return 0
        else
            local exit_code=$?
            
            # Check for "out of extra usage" first (before timeout retry logic)
            # This catches cases where Claude showed the limit message before we timed out
            if check_usage_limit "$output_file"; then
                log "WARN" "🚫 Claude out of extra usage - detected limit message"
                return 5  # Special code for usage limit with reset time
            fi
            
            # Check for timeout (exit code 124)
            if [[ $exit_code -eq 124 ]]; then
                if [[ $timeout_attempt -le $max_timeout_retries ]]; then
                    log "WARN" "⏰ Claude timed out after ${CLAUDE_TIMEOUT_MINUTES} minutes (attempt $timeout_attempt/$((max_timeout_retries + 1)))"
                    log "INFO" "Retrying in 10 seconds..."
                    sleep 10
                    continue  # Retry
                else
                    log "ERROR" "❌ Claude timed out after ${CLAUDE_TIMEOUT_MINUTES} minutes (all $((max_timeout_retries + 1)) attempts exhausted)"
                    return 4  # Special code for timeout after retries
                fi
            else
                log "ERROR" "❌ Claude execution failed with code $exit_code"
            fi
            
            # Check for 5-hour API limit
            if grep -qi "5.*hour.*limit\|limit.*reached\|usage.*limit" "$output_file" 2>/dev/null; then
                log "ERROR" "🚫 Claude API 5-hour usage limit reached"
                return 3  # Special code for API limit
            fi
            
            return 1
        fi
    done
}

# Setup tmux session
setup_tmux() {
    local project_name=$1
    local session_name="ralph-$project_name"
    
    log "INFO" "Setting up tmux session: $session_name"
    
    # Kill existing session if any
    tmux kill-session -t "$session_name" 2>/dev/null || true
    
    # Create new session with the loop
    tmux new-session -d -s "$session_name" -c "$REPO_ROOT"
    
    # Split horizontally
    tmux split-window -h -t "$session_name" -c "$REPO_ROOT"
    
    # Start monitor in right pane
    tmux send-keys -t "$session_name:0.1" "$SCRIPT_DIR/monitor.sh $project_name" Enter
    
    # Build command with options (without --monitor to avoid recursion)
    local start_cmd="$SCRIPT_DIR/start.sh $project_name"
    if [[ $MAX_ITERATIONS -gt 0 ]]; then
        start_cmd="$start_cmd -n $MAX_ITERATIONS"
    fi
    if [[ $MAX_CALLS_PER_HOUR -ne 100 ]]; then
        start_cmd="$start_cmd -c $MAX_CALLS_PER_HOUR"
    fi
    if [[ $CLAUDE_TIMEOUT_MINUTES -ne 20 ]]; then
        start_cmd="$start_cmd -t $CLAUDE_TIMEOUT_MINUTES"
    fi
    if [[ "$COMPLETE_TOKEN" != "<promise>COMPLETE</promise>" ]]; then
        start_cmd="$start_cmd --complete-token '$COMPLETE_TOKEN'"
    fi
    
    # Start loop in left pane
    tmux send-keys -t "$session_name:0.0" "$start_cmd" Enter
    
    # Select left pane
    tmux select-pane -t "$session_name:0.0"
    
    # Set window title
    tmux rename-window -t "$session_name:0" "Ralph: $project_name"
    
    log "SUCCESS" "tmux session created!"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  tmux Controls"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  Ctrl+B, D     - Detach (keeps Ralph running in background)"
    echo "  Ctrl+B, ←/→   - Switch between panes"
    echo "  Ctrl+B, [     - Scroll mode (use arrows, 'q' to exit)"
    echo ""
    echo "  To reattach:  tmux attach -t $session_name"
    echo "  To kill:      tmux kill-session -t $session_name"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    # Attach to session
    tmux attach-session -t "$session_name"
    
    exit 0
}

# Validate that current branch matches prd.json branchName
validate_branch() {
    local project_dir=$1
    local prd_file="$project_dir/prd.json"
    
    local current_branch=$(git branch --show-current 2>/dev/null)
    local expected_branch=$(get_branch_name "$prd_file")
    
    if [[ -z "$current_branch" ]]; then
        log "WARN" "Not in a git repository or detached HEAD"
        return 0
    fi
    
    if [[ -z "$expected_branch" ]]; then
        log "WARN" "No branchName specified in prd.json - skipping branch validation"
        return 0
    fi
    
    if [[ "$current_branch" != "$expected_branch" ]]; then
        echo ""
        log "ERROR" "═══════════════════════════════════════════════════════════"
        log "ERROR" "  BRANCH MISMATCH DETECTED"
        log "ERROR" "═══════════════════════════════════════════════════════════"
        log "ERROR" ""
        log "ERROR" "  Current branch:   $current_branch"
        log "ERROR" "  Expected branch:  $expected_branch"
        log "ERROR" ""
        log "ERROR" "  The prd.json requires work to be done on: $expected_branch"
        log "ERROR" ""
        log "ERROR" "  Please switch to the correct branch:"
        log "ERROR" "    git checkout $expected_branch"
        log "ERROR" ""
        log "ERROR" "═══════════════════════════════════════════════════════════"
        exit 1
    fi
    
    return 0
}

# Confirm current branch before starting
confirm_branch() {
    local project_dir=$1
    local prd_file="$project_dir/prd.json"
    
    local current_branch=$(git branch --show-current 2>/dev/null)
    local expected_branch=$(get_branch_name "$prd_file")

    if [[ -z "$current_branch" ]]; then
        log "WARN" "Not in a git repository or detached HEAD"
        return 0
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Branch: $current_branch"
    if [[ -n "$expected_branch" ]]; then
        echo "  ⚠️  IMPORTANT: You can ONLY push to this branch!"
        echo "  ⚠️  Switching branches during execution is FORBIDDEN."
    fi
    echo "═══════════════════════════════════════════════════════════"
    read -p "Continue? (y/n) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Aborted by user"
        exit 0
    fi

    return 0
}

# Main loop
main_loop() {
    local project_name=$1
    local project_dir="$SCRIPT_DIR/projects/$project_name"
    
    # Ensure logs directory exists
    mkdir -p "$project_dir/logs"
    
    # Set log file for this session
    mkdir -p "$project_dir/logs"
    export LOG_FILE="$project_dir/logs/ralph_$(date '+%Y%m%d').log"
    
    log "SUCCESS" "🚀 Ralph starting for project: $project_name"
    log "INFO" "Max calls/hour: $MAX_CALLS_PER_HOUR | Timeout: ${CLAUDE_TIMEOUT_MINUTES}m"
    if [[ $MAX_ITERATIONS -gt 0 ]]; then
        log "INFO" "Max iterations: $MAX_ITERATIONS"
    else
        log "INFO" "Max iterations: unlimited"
    fi
    log "INFO" "Complete token: $COMPLETE_TOKEN"
    
    # Validate branch matches prd.json branchName
    validate_branch "$project_dir"
    
    # Confirm current branch before starting
    confirm_branch "$project_dir"
    
    # Show initial status
    local total=$(count_total_stories "$project_dir/prd.json")
    local complete=$(count_complete_stories "$project_dir/prd.json")
    log "INFO" "Stories: $complete/$total complete"
    
    # Initialize
    init_rate_limiting "$project_dir"
    init_circuit_breaker "$project_dir"
    
    local loop_count=0
    
    # Main loop
    while true; do
        loop_count=$((loop_count + 1))
        
        if [[ $MAX_ITERATIONS -gt 0 ]]; then
            log "LOOP" "🔁  Loop #$loop_count / $MAX_ITERATIONS"
        else
            log "LOOP" "🔁  Loop #$loop_count"
        fi
        
        # Check max iterations
        if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $loop_count -gt $MAX_ITERATIONS ]]; then
            log "WARN" "✋ Max iterations reached ($MAX_ITERATIONS)"
            update_status "$project_dir" "$loop_count" "max_iterations" ""
            break
        fi
        
        # Check circuit breaker
        if should_halt_execution "$project_dir"; then
            log "ERROR" "═══════════════════════════════════════════════════════════"
            log "ERROR" "  🛑 CIRCUIT BREAKER OPEN - EXECUTION HALTED"
            log "ERROR" "═══════════════════════════════════════════════════════════"
            log "ERROR" ""
            log "ERROR" "  The circuit breaker tripped due to repeated failures"
            log "ERROR" "  or lack of progress."
            log "ERROR" ""
            log "ERROR" "  To reset and continue:"
            log "ERROR" "    ./ralph/start.sh $project_name --reset"
            log "ERROR" ""
            log "ERROR" "═══════════════════════════════════════════════════════════"
            update_status "$project_dir" "$loop_count" "halted" ""
            break
        fi
        
        # Check rate limit
        if ! can_make_call "$project_dir"; then
            wait_for_reset "$project_dir"
            continue
        fi
        
        # Check if all stories are complete BEFORE running Claude
        local incomplete=$(count_incomplete_stories "$project_dir/prd.json")
        if [[ "$incomplete" -eq 0 ]]; then
            log "SUCCESS" "🎉 All stories completed!"
            update_status "$project_dir" "$loop_count" "complete" ""
            
            local total=$(count_total_stories "$project_dir/prd.json")
            log "INFO" "Completed $total stories in $loop_count loops"
            break
        fi
        
        log "INFO" "Incomplete stories: $incomplete"
        update_status "$project_dir" "$loop_count" "running" ""
        
        # Increment call counter
        local calls=$(increment_call_counter "$project_dir")
        log "INFO" "API call $calls/$MAX_CALLS_PER_HOUR this hour"
        
        # Execute Claude with FULL context
        # Capture exit code manually to prevent set -e from exiting on non-zero
        local exec_result=0
        execute_claude "$project_dir" "$loop_count" || exec_result=$?
        
        if [[ $exec_result -eq 0 ]]; then
            update_status "$project_dir" "$loop_count" "success" ""
            log "INFO" "Pausing 5s before next loop..."
            sleep 5
        elif [[ $exec_result -eq 2 ]]; then
            # Project complete
            update_status "$project_dir" "$loop_count" "complete" ""
            log "SUCCESS" "🎉 Project marked as COMPLETE!"
            break
        elif [[ $exec_result -eq 5 ]]; then
            # Usage limit with reset time - wait until reset
            update_status "$project_dir" "$loop_count" "usage_limit" "" || true
            
            # Find the latest log file and wait for reset
            local latest_log
            latest_log=$(ls -t "$project_dir/logs/claude_"*.log 2>/dev/null | head -1) || true
            
            if [[ -n "$latest_log" ]]; then
                wait_for_usage_reset "$latest_log" || sleep 3600
            else
                log "WARN" "Could not find log file, waiting 1 hour..."
                sleep 3600
            fi
            
            log "SUCCESS" "✅ Limit reset! Resuming execution..."
        elif [[ $exec_result -eq 3 ]]; then
            # API limit
            update_status "$project_dir" "$loop_count" "api_limit" ""
            log "ERROR" "API limit reached. Waiting 60 minutes..."
            
            # Countdown
            local wait_seconds=3600
            while [[ $wait_seconds -gt 0 ]]; do
                printf "\r${YELLOW}Time until retry: $(format_duration $wait_seconds)${NC}"
                sleep 10
                wait_seconds=$((wait_seconds - 10))
            done
            printf "\n"
        elif [[ $exec_result -eq 4 ]]; then
            # Timeout after all retries exhausted
            update_status "$project_dir" "$loop_count" "timeout" ""
            log "WARN" "All timeout retries exhausted, waiting 60s before next loop..."
            sleep 60
        else
            update_status "$project_dir" "$loop_count" "error" ""
            log "WARN" "Execution failed, waiting 30s before retry..."
            sleep 30
        fi
        
        log "LOOP" "═══════════════════════════════════════════════════════════"
        log "LOOP" "  End Loop #$loop_count"
        log "LOOP" "═══════════════════════════════════════════════════════════"
        echo ""
    done
    
    log "INFO" "Ralph loop finished"
}

# Show project status
show_status() {
    local project_name=$1
    local project_dir="$SCRIPT_DIR/projects/$project_name"
    
    if [[ ! -f "$project_dir/status.json" ]]; then
        log "ERROR" "No status file found"
        exit 1
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Project: $project_name"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    jq -r '
        "  Status:          \(.status)",
        "  Loop count:      \(.loop_count)",
        "  Current story:   \(.current_story // "none")",
        "  Progress:        \(.stories_complete)/\(.stories_total) stories",
        "  Calls this hour: \(.calls_this_hour)/\(.max_calls_per_hour)",
        "  Last updated:    \(.timestamp)"
    ' "$project_dir/status.json"
    echo ""
    
    # Show incomplete tasks (handle both formats)
    echo "───────────────────────────────────────────────────────────"
    echo "  Pending Tasks"
    echo "───────────────────────────────────────────────────────────"
    jq -r 'if type == "object" then .userStories else . end | [.[] | select(.passes == false)] | sort_by(.priority // 999) | .[:5][] | "  ○ [\(.id)] P\(.priority // "?") \(.title | .[0:45])"' "$project_dir/prd.json" 2>/dev/null || echo "  (none)"
    echo ""
    
    # Show circuit breaker status
    show_circuit_status "$project_dir"
}

# Parse arguments
PROJECT_NAME=""
ACTION="run"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -n|--max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -t|--timeout)
            CLAUDE_TIMEOUT_MINUTES="$2"
            shift 2
            ;;
        --complete-token)
            COMPLETE_TOKEN="$2"
            shift 2
            ;;
        -s|--status)
            ACTION="status"
            shift
            ;;
        -r|--reset)
            ACTION="reset"
            shift
            ;;
        *)
            if [[ -z "$PROJECT_NAME" ]]; then
                PROJECT_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Validate project name
if [[ -z "$PROJECT_NAME" ]]; then
    log "ERROR" "Project name is required"
    show_help
    exit 1
fi

PROJECT_DIR="$SCRIPT_DIR/projects/$PROJECT_NAME"

# Check if project exists
if [[ ! -d "$PROJECT_DIR" ]]; then
    log "ERROR" "Project '$PROJECT_NAME' does not exist"
    log "INFO" "Create it first with: ./ralph/new.sh $PROJECT_NAME"
    exit 1
fi

# Check dependencies
check_dependencies || exit 1

# Execute action
case "$ACTION" in
    "status")
        show_status "$PROJECT_NAME"
        ;;
    "reset")
        reset_circuit_breaker "$PROJECT_DIR" "Manual reset via CLI"
        ;;
    "run")
        if [[ "$USE_TMUX" == "true" ]]; then
            setup_tmux "$PROJECT_NAME"
        else
            main_loop "$PROJECT_NAME"
        fi
        ;;
esac