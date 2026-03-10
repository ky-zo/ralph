#!/bin/bash

# Ralph Convert - Convert PRD.md to prd.json and requirements.md using Claude
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"

CLAUDE_CMD="claude --dangerously-skip-permissions"

# Spinner characters
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
SPINNER_PID=""

# Fun action words that rotate every 10 seconds
SPINNER_WORDS=(
    "Bamboozling"
    "Sibidubing"
    "Percolating"
    "Badabiming"
    "Populating"
    "Conjuring"
    "Manifesting"
    "Synthesizing"
    "Transmuting"
    "Wrangling"
    "👉Fingering👌"
    "Summoning"
    "Orchestrating"
    "Brewing"
    "Concocting"
    "Materializing"
    "Shimshaming"
    "Razzledazzling"
    "Hocuspocusing"
    "Abracadabring"
    "Alakazaming"
    "Zippitydooing"
    "Whizbangifying"
    "Kerfuffling"
    "Discombobulating"
    "Flibbertigibbeting"
    "Gobbledygooking"
    "Hullaballooing"
    "Jiggerypokerying"
    "Lolligagging"
    "Malarkeying"
    "Nambyambying"
    "Pitterpattering"
    "Rambunctifying"
    "Skedaddling"
    "Wibblewobblin"
    "Zigzagging"
    "Bippityboppitying"
    "Splendiferous-ing"
    "Thingamabobbing"
    "Whatchamacalling"
    "Dinglehopping"
    "Snarfblating"
    "Woozlewazzling"
    "Snickerdoodling"
    "Flimflamming"
    "Hobnobbing"
    "Rigmaroling"
    "Wishy-washying"
    "Hodgepodging"
    "Humdinging"
)

# Start spinner in background with rotating fun words
# Usage: start_spinner "Phase description"
start_spinner() {
    local phase_desc="${1:-Processing...}"
    
    # Don't start if already running
    if [[ -n "$SPINNER_PID" ]] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        return
    fi
    
    (
        local i=0
        local word_idx=$((RANDOM % ${#SPINNER_WORDS[@]}))
        local last_word_change=$SECONDS
        local word_count=${#SPINNER_WORDS[@]}
        
        while true; do
            # Change word every 3 seconds (pick random)
            if (( SECONDS - last_word_change >= 3 )); then
                word_idx=$((RANDOM % word_count))
                last_word_change=$SECONDS
            fi
            
            local char="${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1}"
            local action="${SPINNER_WORDS[$word_idx]}"
            printf "\r\033[K${GREEN}%s${NC} %s %s" "$char" "$action" "$phase_desc"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    
    # Ensure spinner is killed on script exit
    trap 'stop_spinner' EXIT
}

# Stop the spinner
stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K"  # Clear the line
    fi
}

# Get relative path from current directory
get_relative_path() {
    local abs_path="$1"
    local cwd="$(pwd)"
    
    # If path starts with cwd, strip it
    if [[ "$abs_path" == "$cwd"/* ]]; then
        echo "${abs_path#$cwd/}"
    else
        echo "$abs_path"
    fi
}

show_help() {
    cat << HELPEOF
Ralph Convert - Convert PRD.md to JSON tasks and requirements

Usage: $0 <project-name>

Arguments:
    project-name    Name of the Ralph project to convert

Examples:
    $0 signals
    $0 pagination

This will run a two-phase conversion process:

Phase 1 - Initial Conversion:
  - Read ralph/projects/<project-name>/prd.md
  - Generate prd.json (actionable user stories)
  - Generate requirements.md (technical specifications)

Phase 2 - Verification:
  - Re-read the original PRD and generated files
  - Verify comprehensive coverage of all requirements
  - Add any missing stories or technical details

HELPEOF
}

# Create conversion prompt
create_conversion_prompt() {
    local project_name=$1
    local project_dir=$2

    cat << PROMPTEOF
# PRD to Tasks Conversion

You are converting a PRD into actionable tasks. Read and edit the following files:

## Files to work with:
- READ: $project_dir/prd.md (the source PRD)
- EDIT: $project_dir/prd.json (write user stories here)
- EDIT: $project_dir/requirements.md (write technical specs here)

## Instructions:

### 1. First, read the PRD file to understand the requirements.

### 2. Edit prd.json with this structure:
\`\`\`json
{
  "branchName": "r/$project_name",
  "userStories": [
    {
      "id": "1.1",
      "title": "Clear one-sentence description starting with action verb",
      "steps": ["Step 1", "Step 2", "Step 3"],
      "acceptanceCriteria": ["Testable criterion 1", "Testable criterion 2"],
      "priority": 1,
      "passes": false
    }
  ]
}
\`\`\`

## Story Size: The Number One Rule

**Each story must be completable in ONE Ralph iteration (one context window).**

Ralph spawns a fresh Amp instance per iteration with no memory of previous work. If a story is too big, the LLM runs out of context before finishing and produces broken code.

### Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):
- "Build the entire dashboard" - Split into: schema, queries, UI components, filters
- "Add authentication" - Split into: schema, middleware, login UI, session handling
- "Refactor the API" - Split into one story per endpoint or pattern

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.
Each task should be completable in one AI run.

## Story Ordering: Dependencies First

Stories execute in priority order. Earlier stories must not depend on later ones.

**Correct order:**
1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

**Wrong order:**
1. UI component (depends on schema that does not exist yet)
2. Schema change

Order by dependencies (infrastructure before features, backend before frontend)

### 3. Edit requirements.md with technical specifications:
- System architecture requirements
- Data models and structures
- API specifications
- User interface requirements
- Performance requirements
- Security considerations

### 4. After editing both files, output a brief summary of what was created.

## Acceptance Criteria: Must Be Verifiable

Each criterion must be something Ralph can CHECK, not something vague.

### Good criteria (verifiable):
- "Add \`status\` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"
- "Tests pass"

### Bad criteria (vague):
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include as final criterion:
\`\`\`
"Typecheck passes"
\`\`\`

For stories with testable logic, also include:
\`\`\`
"Tests pass"
\`\`\`

### For stories that change UI, also include:
\`\`\`
"Verify in browser using agent-browser skill"
\`\`\`

Frontend stories are NOT complete until visually verified. Ralph will use the agent-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Important Requirement
For both files, use simple, direct and informational language. Avoid being verbose where it's not necessary.

## Conversion Rules

1. **Each user story becomes one JSON entry**
2. **IDs**: Sequential (1.1, 1.2, etc.)
3. **Priority**: Based on dependency order, then document order
4. **All stories**: \`passes: false\`.
5. **branchName**: Derive from feature name, kebab-case, prefixed with \`r/\`
6. **Always add**: "Typecheck passes" to every story's acceptance criteria

Now read the PRD and edit the files.
PROMPTEOF
}

# Create verification prompt
create_verification_prompt() {
    local project_dir=$1

    cat << PROMPTEOF
# PRD to JSON Verification

You are verifying that a generated prd.json comprehensively covers all requirements from the original PRD.

## Files to work with:
- READ: $project_dir/prd.md (the original PRD - source of truth)
- READ & EDIT: $project_dir/prd.json (the generated user stories)
- READ & EDIT: $project_dir/requirements.md (the generated technical specs)

## Instructions:

### 1. Carefully read the original PRD.md and understand ALL requirements, features, and details.

### 2. Read the generated prd.json and requirements.md.

### 3. Compare and verify:
- Does prd.json cover ALL features mentioned in the PRD?
- Are there any edge cases, error handling, or UX details in the PRD that are missing from the stories?
- Does requirements.md capture all technical specifications from the PRD?

### 4. If anything is missing or incomplete:
- ADD new user stories to cover missing features
- UPDATE existing stories if their scope is incomplete
- UPDATE requirements.md if technical details are missing
- Ensure all additions follow the same format and guidelines.

## Splitting Large PRDs

If a PRD has big features, split them:

**Original:**
> "Add user notification system"

**Split into:**
1. 1.1: Add notifications table to database
2. 1.2: Create notification service for sending notifications
3. 1.3: Add notification bell icon to header
4. 1.4: Create notification dropdown panel
5. 1.5: Add mark-as-read functionality
6. 1.6: Add notification preferences page

Each is one focused change that can be completed and verified independently.
PROMPTEOF
}

main() {
    local project_name="$1"

    # Validate arguments
    if [[ -z "$project_name" ]]; then
        log "ERROR" "Project name is required"
        show_help
        exit 1
    fi

    local project_dir="$SCRIPT_DIR/projects/$project_name"
    local prd_file="$project_dir/prd.md"
    local json_file="$project_dir/prd.json"
    local req_file="$project_dir/requirements.md"

    # Check if project exists
    if [[ ! -d "$project_dir" ]]; then
        log "ERROR" "Project '$project_name' does not exist"
        log "INFO" "Create it first with: ./ralph/new.sh $project_name"
        exit 1
    fi

    # Check if PRD exists
    if [[ ! -f "$prd_file" ]]; then
        log "ERROR" "PRD file not found: $prd_file"
        exit 1
    fi

    # Check if prd.json already has stories
    if [[ -f "$json_file" ]]; then
        local existing_count
        existing_count=$(jq '.userStories | length' "$json_file" 2>/dev/null || echo "0")
        if [[ "$existing_count" -gt 0 ]]; then
            log "WARN" "prd.json already has $existing_count tasks"
            echo -n "Overwrite? [y/N] "
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log "INFO" "Cancelled"
                exit 0
            fi
        fi
    fi

    log "INFO" "Converting PRD to tasks for project: $project_name"
    log "INFO" "Claude will edit prd.json and requirements.md directly..."

    # Create log directory
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    mkdir -p "$project_dir/logs"

    # ═══════════════════════════════════════════════════════════════════════════
    # PHASE 1: Initial Conversion
    # ═══════════════════════════════════════════════════════════════════════════
    echo ""
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "INFO" "PHASE 1: Converting PRD to tasks"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Create temp file with conversion prompt
    local temp_prompt=$(mktemp)
    create_conversion_prompt "$project_name" "$project_dir" > "$temp_prompt"

    local convert_log="$project_dir/logs/convert_${timestamp}.log"
    log "INFO" "Log file: $(get_relative_path "$convert_log")"

    # Run Claude with spinner
    start_spinner "(Phase 1: Initial conversion)..."
    local convert_success=true
    if ! $CLAUDE_CMD < "$temp_prompt" > "$convert_log" 2>&1; then
        convert_success=false
    fi
    stop_spinner

    rm -f "$temp_prompt"

    if [[ "$convert_success" != "true" ]]; then
        log "ERROR" "Claude conversion failed"
        log "INFO" "Check log: $(get_relative_path "$convert_log")"
        exit 1
    fi

    # Verify files were created
    local story_count=0
    if [[ -f "$json_file" ]]; then
        story_count=$(jq '.userStories | length' "$json_file" 2>/dev/null || echo "0")
    fi

    if [[ "$story_count" -eq 0 ]]; then
        log "ERROR" "prd.json has no tasks - conversion failed"
        log "INFO" "Check the log file: $(get_relative_path "$convert_log")"
        exit 1
    fi

    log "SUCCESS" "Phase 1 complete: Generated $story_count tasks"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # PHASE 2: Verification Loop
    # ═══════════════════════════════════════════════════════════════════════════
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "INFO" "PHASE 2: Verifying completeness against PRD"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Save a copy of current stories for comparison
    local stories_before=$(mktemp)
    cp "$json_file" "$stories_before"

    local verify_prompt=$(mktemp)
    create_verification_prompt "$project_dir" > "$verify_prompt"

    local verify_log="$project_dir/logs/verify_${timestamp}.log"
    log "INFO" "Log file: $(get_relative_path "$verify_log")"

    # Run verification with spinner
    start_spinner "(Phase 2: Verification & gap analysis)..."
    local verify_success=true
    if ! $CLAUDE_CMD < "$verify_prompt" > "$verify_log" 2>&1; then
        verify_success=false
    fi
    stop_spinner

    rm -f "$verify_prompt"

    if [[ "$verify_success" != "true" ]]; then
        log "WARN" "Verification phase failed - but initial conversion succeeded"
        log "INFO" "Check log: $(get_relative_path "$verify_log")"
    else
        # Compare before/after to count added and edited stories
        local added_count=0
        local edited_count=0
        local final_story_count=0
        
        if [[ -f "$json_file" ]]; then
            final_story_count=$(jq '.userStories | length' "$json_file" 2>/dev/null || echo "0")

            # Get IDs from before and after
            local ids_before=$(jq -r '.userStories[].id' "$stories_before" 2>/dev/null | sort)
            local ids_after=$(jq -r '.userStories[].id' "$json_file" 2>/dev/null | sort)
            
            # Count new IDs (added stories)
            while IFS= read -r id; do
                if [[ -n "$id" ]] && ! echo "$ids_before" | grep -qx "$id"; then
                    added_count=$((added_count + 1))
                fi
            done <<< "$ids_after"
            
            # Count edited stories (same ID but different content)
            while IFS= read -r id; do
                if [[ -n "$id" ]] && echo "$ids_after" | grep -qx "$id"; then
                    # Compare the story content (excluding 'passes' which might change)
                    local before_content=$(jq -c --arg id "$id" '.userStories[] | select(.id == $id) | del(.passes)' "$stories_before" 2>/dev/null)
                    local after_content=$(jq -c --arg id "$id" '.userStories[] | select(.id == $id) | del(.passes)' "$json_file" 2>/dev/null)
                    if [[ "$before_content" != "$after_content" ]]; then
                        edited_count=$((edited_count + 1))
                    fi
                fi
            done <<< "$ids_before"
        fi
        
        # Build result message
        local changes=""
        if [[ $added_count -gt 0 ]]; then
            changes="Added $added_count"
        fi
        if [[ $edited_count -gt 0 ]]; then
            if [[ -n "$changes" ]]; then
                changes="$changes, Edited $edited_count"
            else
                changes="Edited $edited_count"
            fi
        fi

        if [[ -n "$changes" ]]; then
            log "SUCCESS" "Phase 2 complete: $changes (total: $final_story_count)"
        else
            log "SUCCESS" "Phase 2 complete: Verified all $final_story_count tasks (no changes needed)"
        fi
    fi
    
    # Cleanup
    rm -f "$stories_before"

    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════════════════════
    local final_count=$(jq '.userStories | length' "$json_file" 2>/dev/null || echo "0")

    echo "═══════════════════════════════════════════════════════"
    echo "  CONVERSION COMPLETE"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "Branch: $(jq -r '.branchName // "not set"' "$json_file")"
    echo "Total tasks: $final_count"
    echo ""
    echo "First 5 tasks (by priority):"
    jq -r '.userStories | sort_by(.priority) | .[:5][] | "  [\(.id)] P\(.priority) \(.title)"' "$json_file"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "Logs:"
    echo "  - Conversion: $(get_relative_path "$convert_log")"
    echo "  - Verification: $(get_relative_path "$verify_log")"
    echo ""
    echo "Next steps:"
    echo "  1. Review: cat $json_file | jq ."
    echo "  2. Start:  ./ralph/start.sh $project_name"
    echo ""
}

# Handle command line arguments
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
        main "$@"
        ;;
esac
