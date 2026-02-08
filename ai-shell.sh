#!/bin/bash
# ai-shell: Natural language shell assistant powered by Claude Haiku
# Memory system: chunk & bundle pattern (inspired by AllProjectWeapons)
# Features: pipe mode, self-correction, self-improvement suggestions

AI_MEMORY_DIR="$HOME/.cache/ai-shell/memory"
AI_MEMORY_INDEX="$AI_MEMORY_DIR/chunks.jsonl"
AI_SHELL_SOURCE="$HOME/.ai-shell.sh"

# --- ASCII art pool (randomly picked per response) ---
_ai_random_art() {
    local -a arts
    arts[0]="   ┌─┐
   ┴─┴
   ಠ_ರೃ  quite."
    arts[1]="   ( •_•)
   ( •_•)>⌐■-■
   (⌐■_■)  deal with it"
    arts[2]="     .  *  .
   *  🐧  *
     .  *  .
   kernel vibes"
    arts[3]="   ┬─┬ ノ( ゜-゜ノ)
   calm down"
    arts[4]="   (╯°□°)╯︵ ┻━┻
   FLIP THE TABLE"
    arts[5]="   ᕦ(ò_óˇ)ᕤ
   flexing on the kernel"
    arts[6]="   ⣿⣿⣿⣿⣿⣿⣿⣿
   ⣿⣿⣇⣀⣀⣇⣿⣿
   ⣿⡏⠉⠉⠉⠉⢹⣿
   ⣿⡏ AI SH ⢹⣿
   ⣿⣇⣀⣀⣀⣀⣸⣿
   a floppy disk"
    arts[7]="   🔥🔥🔥🔥🔥🔥🔥
    this terminal is
      ON FIRE
   🔥🔥🔥🔥🔥🔥🔥"
    arts[8]="   ╱|、
   (˚ˎ 。7
   |、˜〵
   じしˍ,)ノ  meow, nerd"
    arts[9]="   ⠀⣞⢽⢪⢣⢣⢣⢪⡁⡢⣺
   ⠀⢁⢇⢏⢽⢺⣁⡁⠁⠀
   ⠀⡁⣿⢽⡁⢁⠈⠀⠀⡁
   zero bitches?"
    arts[10]="      /\\
     /  \\
    / ai \\
   /______\\
   brainpower"
    arts[11]="   [sudo] password for root:
   lol nice try"
    local idx=$((RANDOM % ${#arts[@]}))
    echo "${arts[$idx]}"
}

_ai_generate_context() {
    local ctx=""
    ctx+="System: $(uname -srm)"$'\n'
    ctx+="Distro: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"$'\n'
    ctx+="CPU: $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"$'\n'
    ctx+="RAM: $(free -h 2>/dev/null | awk '/Mem:/{print $2}')"$'\n'
    ctx+="GPU: $(lspci 2>/dev/null | grep -i 'vga\|3d' | cut -d: -f3- | xargs)"$'\n'
    ctx+="Shell: $SHELL ($BASH_VERSION)"$'\n'
    ctx+="User: $(whoami) | Groups: $(groups 2>/dev/null)"$'\n'
    ctx+="Package manager: $(basename "$(which apt dnf pacman zypper 2>/dev/null | head -1)" 2>/dev/null)"$'\n'
    ctx+="Init: $(ps -p 1 -o comm= 2>/dev/null)"$'\n'
    ctx+="Kernel params: $(cat /proc/cmdline 2>/dev/null)"
    echo "$ctx"
}

_ai_ensure_context() {
    local cache_dir="$HOME/.cache/ai-shell"
    local cache_file="$cache_dir/system-context.txt"
    mkdir -p "$cache_dir"
    if [ ! -f "$cache_file" ] || [ "$(date +%Y%m%d)" != "$(date -r "$cache_file" +%Y%m%d 2>/dev/null)" ]; then
        _ai_generate_context > "$cache_file"
    fi
    cat "$cache_file"
}

# --- MEMORY: Chunk & Bundle ---

_ai_memory_log() {
    local query="$1"
    local command="$2"
    local explanation="$3"
    local output="$4"
    local ts=$(date +%Y-%m-%dT%H:%M:%S)
    local cwd=$(pwd)
    mkdir -p "$AI_MEMORY_DIR"
    output=$(echo "$output" | head -c 500)
    jq -n -c \
        --arg ts "$ts" \
        --arg cwd "$cwd" \
        --arg query "$query" \
        --arg command "$command" \
        --arg explanation "$explanation" \
        --arg output "$output" \
        '{ts: $ts, cwd: $cwd, query: $query, command: $command, explanation: $explanation, output: $output}' \
        >> "$AI_MEMORY_INDEX"
}

_ai_memory_recent() {
    local n=${1:-5}
    if [ ! -f "$AI_MEMORY_INDEX" ]; then
        return
    fi
    tail -n "$n" "$AI_MEMORY_INDEX" | jq -r '"[\(.ts)] Q: \(.query) → \(.command // "no command") | \(.explanation)"' 2>/dev/null
}

_ai_memory_search() {
    local query="$1"
    local max_results=${2:-5}
    if [ ! -f "$AI_MEMORY_INDEX" ]; then
        return
    fi
    local keywords=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -v '^$')
    local results=""
    while IFS= read -r line; do
        local lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        local score=0
        while IFS= read -r kw; do
            if echo "$lower" | grep -q "$kw"; then
                score=$((score + 1))
            fi
        done <<< "$keywords"
        if [ "$score" -gt 0 ]; then
            results+="${score}|${line}"$'\n'
        fi
    done < "$AI_MEMORY_INDEX"
    echo "$results" | sort -t'|' -k1 -rn | head -n "$max_results" | cut -d'|' -f2- | \
        jq -r '"[\(.ts)] Q: \(.query) → $ \(.command // "n/a")\n  \(.explanation)\n  Output: \(.output | if length > 200 then .[:200] + "..." else . end)"' 2>/dev/null
}

_ai_memory_bundle() {
    local query="$1"
    local bundle=""
    local recent=$(_ai_memory_recent 5)
    if [ -n "$recent" ]; then
        bundle+="RECENT HISTORY (last 5 commands):"$'\n'
        bundle+="$recent"$'\n'$'\n'
    fi
    local recall=$(_ai_memory_search "$query" 3)
    if [ -n "$recall" ]; then
        bundle+="RELEVANT PAST INTERACTIONS:"$'\n'
        bundle+="$recall"$'\n'
    fi
    echo "$bundle"
}

# --- SELF-CORRECTION: detect bad output and auto-retry ---

_ai_detect_failure() {
    local output="$1"
    local exit_code="$2"

    # Non-zero exit code
    if [ "$exit_code" -ne 0 ] 2>/dev/null; then
        echo "Command exited with code $exit_code"
        return 0
    fi

    # Common failure patterns
    if echo "$output" | grep -qi "command not found"; then
        echo "Command not found"
        return 0
    fi
    if echo "$output" | grep -qi "No such file or directory"; then
        echo "File or directory not found"
        return 0
    fi
    if echo "$output" | grep -qi "Permission denied"; then
        echo "Permission denied"
        return 0
    fi
    if echo "$output" | grep -qi "^Usage:\|^usage:"; then
        if [ "$(echo "$output" | wc -l)" -gt 5 ]; then
            echo "Got help/usage text instead of actual output"
            return 0
        fi
    fi
    if echo "$output" | grep -qi "invalid option\|unrecognized option\|illegal option"; then
        echo "Invalid command option"
        return 0
    fi

    return 1
}

_ai_retry() {
    local api_key="$1"
    local system_prompt="$2"
    local original_query="$3"
    local failed_cmd="$4"
    local failure_reason="$5"
    local failed_output="$6"

    local retry_query="My previous query was: $original_query
You suggested: $failed_cmd
But it failed. Reason: $failure_reason
Output was: $(echo "$failed_output" | head -c 300)
Give me a corrected command that actually works."

    echo -e "\033[0;90mSelf-correcting...\033[0m"

    local response
    response=$(curl -s --max-time 15 https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg system "$system_prompt" \
            --arg query "$retry_query" \
            '{
                model: "claude-haiku-4-5-20251001",
                max_tokens: 1024,
                system: $system,
                messages: [{role: "user", content: $query}]
            }')" 2>/dev/null)

    echo "$response" | jq -r '.content[0].text' 2>/dev/null
}

# --- SELF-IMPROVEMENT: read own source, suggest improvements ---

_ai_self_improve() {
    local api_key="$1"
    local query="$2"

    # Read own source code (truncated to keep tokens low)
    local own_source=$(head -c 3000 "$AI_SHELL_SOURCE" 2>/dev/null)

    # Get recent memory for usage pattern analysis
    local recent_memory=""
    if [ -f "$AI_MEMORY_INDEX" ]; then
        recent_memory=$(tail -n 10 "$AI_MEMORY_INDEX" | jq -r '"Q: \(.query) → \(.command // "n/a") | exit output length: \(.output | length)"' 2>/dev/null)
    fi

    local improve_prompt="You are a bash script that is reading your own source code. You are ~/.ai-shell.sh — a natural language shell assistant.

YOUR SOURCE CODE (first 3000 chars):
$own_source

RECENT USER INTERACTIONS:
$recent_memory

LAST USER QUERY: $query

Based on the user interaction patterns you see in the memory, and your knowledge of your own source code, suggest ONE specific, practical improvement to yourself. Think about:
- What the user does most often
- What failed or was awkward
- Missing features that would help THIS specific user
- Performance or UX improvements
- Things the user would think are cool

Respond with ONLY a JSON object, no markdown fences:
{\"suggestion\": \"one concise sentence describing the improvement\", \"reason\": \"why this would help based on the usage patterns you see\"}"

    local response
    response=$(curl -s --max-time 10 https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg system "$improve_prompt" \
            --arg query "Analyze yourself and suggest one improvement." \
            '{
                model: "claude-haiku-4-5-20251001",
                max_tokens: 256,
                system: $system,
                messages: [{role: "user", content: $query}]
            }')" 2>/dev/null)

    local text=$(echo "$response" | jq -r '.content[0].text' 2>/dev/null)
    if [ -z "$text" ] || [ "$text" = "null" ]; then
        return
    fi

    text=$(echo "$text" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n')

    local suggestion=$(echo "$text" | jq -r '.suggestion // empty' 2>/dev/null)
    local reason=$(echo "$text" | jq -r '.reason // empty' 2>/dev/null)

    if [ -n "$suggestion" ]; then
        echo -e "\033[0;93m💡 Self-improvement: $suggestion\033[0m"
        if [ -n "$reason" ]; then
            echo -e "\033[0;93m   Reason: $reason\033[0m"
        fi
    fi
}

# --- API CALL HELPER ---

_ai_call_api() {
    local api_key="$1"
    local system_prompt="$2"
    local user_msg="$3"
    local max_tokens="${4:-1024}"

    curl -s --max-time 15 https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg system "$system_prompt" \
            --arg query "$user_msg" \
            --argjson max_tokens "$max_tokens" \
            '{
                model: "claude-haiku-4-5-20251001",
                max_tokens: $max_tokens,
                system: $system,
                messages: [{role: "user", content: $query}]
            }')" 2>/dev/null
}

# --- MAIN ---

ai() {
    # Handle subcommands
    case "$1" in
        recall)
            shift
            if [ -z "$*" ]; then
                echo "Usage: ai recall <search query>"
                return 1
            fi
            echo -e "\033[0;36mSearching memory for: $*\033[0m"
            echo ""
            local hits=$(_ai_memory_search "$*" 10)
            if [ -n "$hits" ]; then
                echo "$hits"
            else
                echo "No matching memories found."
            fi
            return 0
            ;;
        history)
            if [ ! -f "$AI_MEMORY_INDEX" ]; then
                echo "No history yet."
                return 0
            fi
            local count=$(wc -l < "$AI_MEMORY_INDEX")
            echo -e "\033[0;36m$count interactions logged\033[0m"
            echo ""
            _ai_memory_recent 20
            return 0
            ;;
        forget)
            if [ -f "$AI_MEMORY_INDEX" ]; then
                rm "$AI_MEMORY_INDEX"
                echo "Memory wiped."
            else
                echo "Nothing to forget."
            fi
            return 0
            ;;
    esac

    local query="$*"

    # --- PIPE MODE: detect stdin and include as context ---
    local piped_input=""
    if [ ! -t 0 ]; then
        piped_input=$(cat | head -c 4000)
        if [ -z "$query" ]; then
            query="analyze this output"
        fi
    fi

    if [ -z "$query" ]; then
        echo "Usage: ai <what you want to do>"
        echo "       ai recall <search query>   -- search past interactions"
        echo "       ai history                  -- show recent history"
        echo "       ai forget                   -- wipe memory"
        echo "       ask                         -- interactive mode (handles special chars)"
        echo "       <cmd> | ai <question>       -- pipe mode (analyze output)"
        return 1
    fi

    local key_file="$HOME/.config/ai-shell/api-key"
    if [ ! -f "$key_file" ]; then
        echo "Error: No API key found at $key_file"
        echo "Get one from https://console.anthropic.com/"
        return 1
    fi
    local api_key=$(cat "$key_file")

    local context=$(_ai_ensure_context)
    local cwd=$(pwd)
    local memory=$(_ai_memory_bundle "$query")

    # Build the user message — include piped input if present
    local user_message="$query"
    if [ -n "$piped_input" ]; then
        user_message="$query

PIPED INPUT (output from a previous command the user wants you to analyze):
$piped_input"
    fi

    local system_prompt
    system_prompt="You are a concise Linux shell assistant. The user describes what they want in plain English. You return a JSON object.
Also, tell a one sentence story explaining 1 interesting fact about the commands that you suggested, designed to educate and entertain the user.

SYSTEM CONTEXT:
$context

CURRENT DIRECTORY: $cwd

${memory:+MEMORY (previous interactions for context):
$memory
}RESPOND WITH ONLY a JSON object, no markdown fences, no extra text:
{\"options\": [{\"command\": \"first approach\", \"label\": \"short 3-5 word description\"}, {\"command\": \"second approach\", \"label\": \"short description\"}, {\"command\": \"third approach\", \"label\": \"short description\"}], \"explanation\": \"one sentence explaining the situation\", \"funfact\": \"one interesting fact about the commands\", \"linus\": \"a real Linus Torvalds quote, relevant to the topic if possible\", \"roast\": \"absolutely DESTROY the user for needing AI help with this. Be unhinged, mass disrespect, no mercy. Imagine a comedian who got fired for going too far. Swearing encouraged. Make it hurt so good.\"}

RULES:
- Always provide exactly 3 options in the options array, ordered from most recommended to least.
- Each option should be a different valid approach to solve the user request.
- If the user piped input to you, analyze it and provide commands or answers relevant to that input.
- If the question doesnt need a command, set all commands to null and answer in explanation.
- Use only tools available on their system.
- Prefer simple, safe, non-destructive commands.
- For destructive ops (rm, dd, mkfs, format), always warn in the explanation.
- For multi-step tasks, chain with && or use a subshell.
- Keep explanations to one sentence.
- You have access to the users command history in MEMORY. Use it to give smarter, context-aware answers."

    echo -e "\033[0;90mThinking...\033[0m"

    local response
    response=$(_ai_call_api "$api_key" "$system_prompt" "$user_message" 1024)

    if [ -z "$response" ]; then
        echo -e "\033[0;31mError: No response from API (network issue or timeout)\033[0m"
        return 1
    fi

    local err_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$err_msg" ]; then
        echo -e "\033[0;31mAPI Error: $err_msg\033[0m"
        return 1
    fi

    local text=$(echo "$response" | jq -r '.content[0].text' 2>/dev/null)

    if [ -z "$text" ] || [ "$text" = "null" ]; then
        echo -e "\033[0;31mError: Unexpected API response\033[0m"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 1
    fi

    text=$(echo "$text" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n')

    local explanation=$(echo "$text" | jq -r '.explanation // empty' 2>/dev/null)
    local funfact=$(echo "$text" | jq -r '.funfact // empty' 2>/dev/null)
    local linus=$(echo "$text" | jq -r '.linus // empty' 2>/dev/null)
    local roast=$(echo "$text" | jq -r '.roast // empty' 2>/dev/null)

    local cmd1=$(echo "$text" | jq -r '.options[0].command // empty' 2>/dev/null)
    local lbl1=$(echo "$text" | jq -r '.options[0].label // empty' 2>/dev/null)
    local cmd2=$(echo "$text" | jq -r '.options[1].command // empty' 2>/dev/null)
    local lbl2=$(echo "$text" | jq -r '.options[1].label // empty' 2>/dev/null)
    local cmd3=$(echo "$text" | jq -r '.options[2].command // empty' 2>/dev/null)
    local lbl3=$(echo "$text" | jq -r '.options[2].label // empty' 2>/dev/null)

    if [ -z "$explanation" ]; then
        echo "$text"
        return
    fi

    # Clear "Thinking..." line
    echo -en "\033[1A\033[2K"

    echo -e "\033[0;36m→ $explanation\033[0m"
    echo ""

    # Show 3 options and execute
    if [ -n "$cmd1" ] && [ "$cmd1" != "null" ]; then
        echo -e "  \033[1;32m[1]\033[0m \033[0;32m$lbl1\033[0m"
        echo -e "      \033[1;33m\$ $cmd1\033[0m"
        echo -e "  \033[1;34m[2]\033[0m \033[0;34m$lbl2\033[0m"
        echo -e "      \033[1;33m\$ $cmd2\033[0m"
        echo -e "  \033[1;35m[3]\033[0m \033[0;35m$lbl3\033[0m"
        echo -e "      \033[1;33m\$ $cmd3\033[0m"
        echo ""

        local choice
        read -p "Pick [1/2/3] or q to cancel: " choice

        local selected_cmd=""
        case "$choice" in
            1) selected_cmd="$cmd1" ;;
            2) selected_cmd="$cmd2" ;;
            3) selected_cmd="$cmd3" ;;
            *) echo "Cancelled."; return 0 ;;
        esac

        echo ""
        echo -e "\033[1;33m  \$ $selected_cmd\033[0m"
        echo ""

        local cmd_output
        cmd_output=$(eval "$selected_cmd" 2>&1)
        local cmd_exit=$?
        echo "$cmd_output"

        # --- SELF-CORRECTION: detect failure and auto-retry once ---
        local failure_reason
        failure_reason=$(_ai_detect_failure "$cmd_output" "$cmd_exit")
        if [ $? -eq 0 ] && [ -n "$failure_reason" ]; then
            echo ""
            echo -e "\033[0;31m✗ Detected failure: $failure_reason\033[0m"

            local retry_text
            retry_text=$(_ai_retry "$api_key" "$system_prompt" "$query" "$selected_cmd" "$failure_reason" "$cmd_output")

            if [ -n "$retry_text" ]; then
                retry_text=$(echo "$retry_text" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n')
                local retry_cmd=$(echo "$retry_text" | jq -r '.options[0].command // empty' 2>/dev/null)
                local retry_expl=$(echo "$retry_text" | jq -r '.explanation // empty' 2>/dev/null)

                if [ -n "$retry_cmd" ] && [ "$retry_cmd" != "null" ]; then
                    echo -e "\033[0;36m→ Retry: $retry_expl\033[0m"
                    echo -e "\033[1;33m  \$ $retry_cmd\033[0m"
                    echo ""

                    local retry_choice
                    read -p "Run corrected command? [Y/n] " retry_choice
                    if [[ "$retry_choice" =~ ^[Yy]?$ ]]; then
                        cmd_output=$(eval "$retry_cmd" 2>&1)
                        echo "$cmd_output"
                        selected_cmd="$retry_cmd"
                    fi
                fi
            fi
        fi

        _ai_memory_log "$query" "$selected_cmd" "$explanation" "$cmd_output"
    else
        _ai_memory_log "$query" "" "$explanation" ""
    fi

    if [ -n "$funfact" ]; then
        echo ""
        echo -e "\033[0;32m✦ $funfact\033[0m"
    fi

    if [ -n "$linus" ]; then
        echo -e "\033[0;31m🐧 \"$linus\" -- Linus Torvalds\033[0m"
    fi

    # Roast mode: export AI_ROAST=1 to enable. Not corny.
    if [ -n "$roast" ] && [ "${AI_ROAST:-0}" = "1" ]; then
        echo -e "\033[1;90m🔥 $roast\033[0m"
    fi

    # Random ASCII art footer
    echo ""
    echo -e "\033[0;90m$(_ai_random_art)\033[0m"

    # --- SELF-IMPROVEMENT: read own code, analyze usage, suggest one improvement ---
    _ai_self_improve "$api_key" "$query" &
    wait $! 2>/dev/null
}

# Interactive mode: reads raw input so apostrophes, quotes, etc. just work
ask() {
    echo -ne "\033[0;36mai> \033[0m"
    local raw_query
    read -r raw_query
    if [ -z "$raw_query" ]; then
        echo "No query entered."
        return 1
    fi
    raw_query=$(echo "$raw_query" | tr -d "'\`")
    ai $raw_query
}
