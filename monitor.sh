#!/bin/bash

# Ralph Monitor - Live status dashboard
# Displays project status in real-time

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"

# Refresh interval in seconds
REFRESH_INTERVAL=5

show_help() {
    cat << HELPEOF
Ralph Monitor - Live status dashboard

Usage: $0 <project-name>

Arguments:
    project-name    Name of the Ralph project to monitor

Examples:
    $0 signals

Press Ctrl+C to exit.

HELPEOF
}

# Move cursor to top (no clear = no flicker)
clear_screen() {
    printf "\033[H"
}

# Draw progress bar
draw_progress_bar() {
    local current=$1
    local total=$2
    local width=30
    
    if [[ $total -eq 0 ]]; then
        printf "[%-${width}s] 0%%" ""
        return
    fi
    
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %d%%" "$percent"
}

# Get circuit breaker status with color
get_circuit_status_colored() {
    local project_dir=$1
    local cb_file="$project_dir/.circuit_breaker.json"
    
    if [[ ! -f "$cb_file" ]]; then
        echo -e "${GREEN}CLOSED ✓${NC}"
        return
    fi
    
    local state=$(jq -r '.state' "$cb_file")
    
    case "$state" in
        "CLOSED")    echo -e "${GREEN}CLOSED ✓${NC}" ;;
        "HALF_OPEN") echo -e "${YELLOW}HALF_OPEN ⚠${NC}" ;;
        "OPEN")      echo -e "${RED}OPEN ✗${NC}" ;;
        *)           echo -e "${BLUE}UNKNOWN${NC}" ;;
    esac
}

# Get status with color
get_status_colored() {
    local status=$1
    
    case "$status" in
        "running")   echo -e "${GREEN}● RUNNING${NC}" ;;
        "success")   echo -e "${GREEN}✓ SUCCESS${NC}" ;;
        "complete")  echo -e "${GREEN}🎉 COMPLETE${NC}" ;;
        "error")     echo -e "${RED}✗ ERROR${NC}" ;;
        "halted")    echo -e "${RED}⛔ HALTED${NC}" ;;
        "created")   echo -e "${BLUE}○ CREATED${NC}" ;;
        *)           echo -e "${YELLOW}? $status${NC}" ;;
    esac
}

# Display dashboard
display_dashboard() {
    local project_name=$1
    local project_dir="$SCRIPT_DIR/projects/$project_name"
    local status_file="$project_dir/status.json"
    local prd_file="$project_dir/prd.json"
    local analysis_file="$project_dir/.last_analysis.json"
    
    clear_screen
    
    # Header
    echo ""  # Push content below tmux border
    echo -e "${PURPLE}════════════════════════════════════════════════════════${NC}"
    echo -e "                    ${CYAN}RALPH MONITOR${NC} - $project_name             "
    echo -e "${PURPLE}════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check if status file exists
    if [[ ! -f "$status_file" ]]; then
        echo -e "${YELLOW}Waiting for Ralph to start...${NC}"
        echo ""
        echo "Run: ./ralph/start.sh $project_name"
        return
    fi
    
    # Read status
    local status=$(jq -r '.status // "unknown"' "$status_file")
    local loop_count=$(jq -r '.loop_count // 0' "$status_file")
    local current_story=$(jq -r '.current_story // "none"' "$status_file")
    local complete=$(jq -r '.stories_complete // 0' "$status_file")
    local total=$(jq -r '.stories_total // 0' "$status_file")
    local calls=$(jq -r '.calls_this_hour // 0' "$status_file")
    local max_calls=$(jq -r '.max_calls_per_hour // 100' "$status_file")
    local timestamp=$(jq -r '.timestamp // "unknown"' "$status_file")
    
    # Main status
    echo -e "  ${BLUE}Status:${NC}        $(get_status_colored "$status")"
    echo -e "  ${BLUE}Loop:${NC}          #$loop_count"
    echo -e "  ${BLUE}Current Story:${NC} $current_story"
    echo ""
    
    # Progress
    echo -e "  ${BLUE}Progress:${NC}      $complete / $total stories"
    echo -n "                 "
    draw_progress_bar "$complete" "$total"
    echo ""
    echo ""
    
    # Rate limiting
    echo -e "  ${BLUE}API Calls:${NC}     $calls / $max_calls this hour"
    echo -n "                 "
    draw_progress_bar "$calls" "$max_calls"
    echo ""
    echo ""
    
    # Circuit breaker
    echo -e "  ${BLUE}Circuit:${NC}       $(get_circuit_status_colored "$project_dir")"
    echo ""
    
    # Last analysis (if available)
    if [[ -f "$analysis_file" ]]; then
        echo -e "${PURPLE}─────────────────────────────────────────────────────────${NC}"
        echo -e "  ${CYAN}Last Analysis${NC}"
        echo ""
        
        local tests=$(jq -r '.tests_status // "N/A"' "$analysis_file")
        local work=$(jq -r '.work_type // "N/A"' "$analysis_file")
        local files=$(jq -r '.files_modified // 0' "$analysis_file")
        local tasks=$(jq -r '.userStories_completed // 0' "$analysis_file")
        local exit_sig=$(jq -r '.exit_signal // false' "$analysis_file")
        
        echo -e "  Tests:         ${tests}"
        echo -e "  Work Type:     ${work}"
        echo -e "  Files Changed: ${files}"
        echo -e "  Exit Signal:   ${exit_sig}"
    fi
    
    # Recent stories
    echo ""
    echo -e "${PURPLE}─────────────────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}Stories${NC}"
    echo ""
    
    if [[ -f "$prd_file" ]]; then
        # Show branch name if available
        local branch_name=$(jq -r '.branchName // empty' "$prd_file" 2>/dev/null)
        if [[ -n "$branch_name" ]]; then
            echo -e "  ${BLUE}Branch:${NC} $branch_name"
            echo ""
        fi
        
        # Show incomplete stories (max 5) - handle both formats, sorted by priority
        local incomplete=$(jq -r 'if type == "object" then .userStories else . end | [.[] | select(.passes == false)] | sort_by(.priority // 999) | .[:5][] | "  ○ [\(.id)] P\(.priority // "?") \(.title | .[0:40])"' "$prd_file" 2>/dev/null)
        if [[ -n "$incomplete" ]]; then
            echo -e "${YELLOW}Pending:${NC}"
            echo "$incomplete"
        fi
        
        # Show recently completed (max 3)
        local completed=$(jq -r 'if type == "object" then .userStories else . end | [.[] | select(.passes == true)] | .[-3:][] | "  ✓ [\(.id)] \(.title | .[0:40])"' "$prd_file" 2>/dev/null)
        if [[ -n "$completed" ]]; then
            echo ""
            echo -e "${GREEN}Completed:${NC}"
            echo "$completed"
        fi
    fi
    
    # Footer
    echo ""
    echo -e "${PURPLE}─────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BLUE}Last Update:${NC}   $timestamp"
    echo -e "  ${BLUE}Refresh:${NC}       Every ${REFRESH_INTERVAL}s | Press Ctrl+C to exit"
}

# Main function
main() {
    local project_name=$1
    
    if [[ -z "$project_name" ]]; then
        show_help
        exit 1
    fi
    
    local project_dir="$SCRIPT_DIR/projects/$project_name"
    
    if [[ ! -d "$project_dir" ]]; then
        echo -e "${RED}Error: Project '$project_name' does not exist${NC}"
        exit 1
    fi
    
    # Trap Ctrl+C for clean exit
    trap 'echo ""; echo "Monitor stopped."; exit 0' SIGINT SIGTERM
    
    # Main loop
    while true; do
        display_dashboard "$project_name"
        sleep "$REFRESH_INTERVAL"
    done
}

# Handle arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        show_help
        exit 1
        ;;
    *)
        main "$1"
        ;;
esac
