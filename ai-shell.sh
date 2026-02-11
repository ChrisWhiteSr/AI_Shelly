#!/bin/bash
# ai-shell: Natural language shell assistant powered by AI
# Features: multi-provider, configurable outputs, intent-aware, memory, self-correction

# --- PATHS ---
AI_CONFIG_DIR="$HOME/.config/ai-shell"
AI_CONFIG_FILE="$AI_CONFIG_DIR/config.json"
AI_CACHE_DIR="$HOME/.cache/ai-shell"
AI_MEMORY_DIR="$AI_CACHE_DIR/memory"
AI_MEMORY_INDEX="$AI_MEMORY_DIR/chunks.jsonl"
AI_CONVERSATION_FILE="$AI_CACHE_DIR/conversation.json"
AI_SHELL_SOURCE="$HOME/.ai-shell.sh"

# ═══════════════════════════════════════
# CONFIG SYSTEM
# ═══════════════════════════════════════

_ai_load_config() {
    local key="$1"
    local default="$2"
    if [ -f "$AI_CONFIG_FILE" ]; then
        local val=$(jq -r "$key // empty" "$AI_CONFIG_FILE" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

_ai_feature_enabled() {
    local feature="$1"
    local val=$(_ai_load_config ".features.$feature" "true")
    [ "$val" = "true" ]
}

_ai_set_config() {
    local key="$1"
    local value="$2"
    mkdir -p "$AI_CONFIG_DIR"
    if [ ! -f "$AI_CONFIG_FILE" ]; then
        echo '{}' > "$AI_CONFIG_FILE"
    fi
    local tmp=$(mktemp)
    jq "$key = $value" "$AI_CONFIG_FILE" > "$tmp" && mv "$tmp" "$AI_CONFIG_FILE"
}

_ai_show_config() {
    if [ ! -f "$AI_CONFIG_FILE" ]; then
        echo "No config file found. Run the installer or use 'ai config set'."
        return 1
    fi
    echo -e "\033[1m┌─ AI Shelly Configuration ─┐\033[0m"
    echo ""
    local provider=$(_ai_load_config ".provider" "anthropic")
    local model=$(_ai_load_config ".model" "claude-haiku-4-5-20251001")
    echo -e "  Provider:     \033[0;36m$provider\033[0m"
    echo -e "  Model:        \033[0;36m$model\033[0m"
    echo ""
    echo -e "  \033[1mFeatures:\033[0m"
    for feat in funfact linus_quotes ascii_art roast self_improve; do
        local val=$(_ai_load_config ".features.$feat" "true")
        local icon="✓"
        local color="\033[0;32m"
        if [ "$val" != "true" ]; then
            icon="✗"
            color="\033[0;31m"
        fi
        printf "    ${color}${icon}\033[0m %-18s %s\n" "$feat" "($val)"
    done
    echo ""
    local buf_size=$(_ai_load_config ".conversation.buffer_size" "3")
    local timeout=$(_ai_load_config ".conversation.timeout_seconds" "1800")
    echo -e "  \033[1mConversation:\033[0m"
    echo "    Buffer size:  $buf_size exchanges"
    echo "    Timeout:      ${timeout}s"
    echo ""
    echo -e "  Config file: \033[0;90m$AI_CONFIG_FILE\033[0m"
}

# ═══════════════════════════════════════
# ASCII ART POOL
# ═══════════════════════════════════════

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

# ═══════════════════════════════════════
# SYSTEM CONTEXT
# ═══════════════════════════════════════

_ai_generate_context() {
    local ctx=""
    local os_type=$(uname -s 2>/dev/null)
    ctx+="System: $(uname -srm)"$'\n'

    if [ -f /etc/os-release ]; then
        ctx+="Distro: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"$'\n'
    elif [ "$os_type" = "Darwin" ]; then
        ctx+="Distro: macOS $(sw_vers -productVersion 2>/dev/null)"$'\n'
    fi

    if [ -f /proc/cpuinfo ]; then
        ctx+="CPU: $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"$'\n'
    elif [ "$os_type" = "Darwin" ]; then
        ctx+="CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"$'\n'
    fi

    if command -v free &>/dev/null; then
        ctx+="RAM: $(free -h 2>/dev/null | awk '/Mem:/{print $2}')"$'\n'
    elif [ "$os_type" = "Darwin" ]; then
        local mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        if [ -n "$mem_bytes" ]; then
            ctx+="RAM: $((mem_bytes / 1073741824))G"$'\n'
        fi
    fi

    if command -v lspci &>/dev/null; then
        ctx+="GPU: $(lspci 2>/dev/null | grep -i 'vga\|3d' | cut -d: -f3- | xargs)"$'\n'
    elif [ "$os_type" = "Darwin" ]; then
        ctx+="GPU: $(system_profiler SPDisplaysDataType 2>/dev/null | grep 'Chipset Model' | cut -d: -f2 | xargs)"$'\n'
    fi

    ctx+="Shell: $SHELL ($BASH_VERSION)"$'\n'
    ctx+="User: $(whoami) | Groups: $(groups 2>/dev/null)"$'\n'

    local pkg_mgr=""
    for pm in apt dnf pacman zypper brew; do
        if command -v "$pm" &>/dev/null; then
            pkg_mgr="$pm"
            break
        fi
    done
    ctx+="Package manager: ${pkg_mgr:-unknown}"$'\n'
    ctx+="Init: $(ps -p 1 -o comm= 2>/dev/null)"$'\n'
    if [ -f /proc/cmdline ]; then
        ctx+="Kernel params: $(cat /proc/cmdline 2>/dev/null)"
    fi
    echo "$ctx"
}

_ai_ensure_context() {
    local cache_file="$AI_CACHE_DIR/system-context.txt"
    mkdir -p "$AI_CACHE_DIR"
    if [ ! -f "$cache_file" ] || [ "$(date +%Y%m%d)" != "$(date -r "$cache_file" +%Y%m%d 2>/dev/null)" ]; then
        _ai_generate_context > "$cache_file"
    fi
    cat "$cache_file"
}

# ═══════════════════════════════════════
# MEMORY SYSTEM (chunk & bundle)
# ═══════════════════════════════════════

_ai_memory_log() {
    local query="$1" command="$2" explanation="$3" output="$4"
    local ts=$(date +%Y-%m-%dT%H:%M:%S)
    local cwd=$(pwd)
    mkdir -p "$AI_MEMORY_DIR"
    output=$(echo "$output" | head -c 500)
    jq -n -c \
        --arg ts "$ts" --arg cwd "$cwd" --arg query "$query" \
        --arg command "$command" --arg explanation "$explanation" --arg output "$output" \
        '{ts:$ts, cwd:$cwd, query:$query, command:$command, explanation:$explanation, output:$output}' \
        >> "$AI_MEMORY_INDEX"
}

_ai_memory_recent() {
    local n=${1:-5}
    [ ! -f "$AI_MEMORY_INDEX" ] && return
    tail -n "$n" "$AI_MEMORY_INDEX" | jq -r '"[\(.ts)] Q: \(.query) → \(.command // "no command") | \(.explanation)"' 2>/dev/null
}

_ai_memory_search() {
    local query="$1" max_results=${2:-5}
    [ ! -f "$AI_MEMORY_INDEX" ] && return
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
        bundle+="RECENT HISTORY (last 5 commands):"$'\n'"$recent"$'\n\n'
    fi
    local recall=$(_ai_memory_search "$query" 3)
    if [ -n "$recall" ]; then
        bundle+="RELEVANT PAST INTERACTIONS:"$'\n'"$recall"$'\n'
    fi
    echo "$bundle"
}

# ═══════════════════════════════════════
# CONVERSATION BUFFER (last N exchanges)
# ═══════════════════════════════════════

_ai_conversation_init() {
    mkdir -p "$AI_CACHE_DIR"
    [ ! -f "$AI_CONVERSATION_FILE" ] && echo '[]' > "$AI_CONVERSATION_FILE"
}

_ai_conversation_expired() {
    local timeout=$(_ai_load_config ".conversation.timeout_seconds" "1800")
    if [ ! -f "$AI_CONVERSATION_FILE" ]; then return 0; fi
    local last_ts=$(jq -r '.[-1].ts // 0' "$AI_CONVERSATION_FILE" 2>/dev/null)
    [ "$last_ts" = "0" ] || [ "$last_ts" = "null" ] && return 0
    local now=$(date +%s)
    local diff=$((now - last_ts))
    [ "$diff" -gt "$timeout" ] && return 0
    return 1
}

_ai_conversation_add() {
    local role="$1" content="$2"
    _ai_conversation_init
    local ts=$(date +%s)
    local buf_size=$(_ai_load_config ".conversation.buffer_size" "3")
    local max_entries=$((buf_size * 2))

    # If conversation expired, reset it
    if _ai_conversation_expired; then
        echo '[]' > "$AI_CONVERSATION_FILE"
    fi

    local tmp=$(mktemp)
    jq --arg role "$role" --arg content "$content" --argjson ts "$ts" --argjson max "$max_entries" \
        '. + [{role: $role, content: $content, ts: $ts}] | .[-$max:]' \
        "$AI_CONVERSATION_FILE" > "$tmp" && mv "$tmp" "$AI_CONVERSATION_FILE"
}

_ai_conversation_get_messages() {
    _ai_conversation_init
    if _ai_conversation_expired; then
        echo '[]'
        return
    fi
    jq '[.[] | {role: .role, content: .content}]' "$AI_CONVERSATION_FILE" 2>/dev/null || echo '[]'
}

_ai_conversation_clear() {
    echo '[]' > "$AI_CONVERSATION_FILE" 2>/dev/null
}

# ═══════════════════════════════════════
# SELF-CORRECTION
# ═══════════════════════════════════════

_ai_detect_failure() {
    local output="$1" exit_code="$2"
    if [ "$exit_code" -ne 0 ] 2>/dev/null; then echo "Command exited with code $exit_code"; return 0; fi
    if echo "$output" | grep -qi "command not found"; then echo "Command not found"; return 0; fi
    if echo "$output" | grep -qi "No such file or directory"; then echo "File or directory not found"; return 0; fi
    if echo "$output" | grep -qi "Permission denied"; then echo "Permission denied"; return 0; fi
    if echo "$output" | grep -qi "invalid option\|unrecognized option\|illegal option"; then echo "Invalid command option"; return 0; fi
    return 1
}

# ═══════════════════════════════════════
# MULTI-PROVIDER API CALLS
# ═══════════════════════════════════════

_ai_call_anthropic() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="$4" model="$5"
    curl -s --max-time 30 https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg system "$system_prompt" \
            --argjson messages "$messages_json" \
            --argjson max_tokens "$max_tokens" \
            --arg model "$model" \
            '{model:$model, max_tokens:$max_tokens, system:$system, messages:$messages}')" 2>/dev/null
}

_ai_call_openai() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="$4" model="$5"
    local full_messages=$(jq -n --arg sys "$system_prompt" --argjson msgs "$messages_json" \
        '[{role:"system",content:$sys}] + $msgs')
    curl -s --max-time 30 https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $api_key" \
        -d "$(jq -n \
            --argjson messages "$full_messages" \
            --argjson max_tokens "$max_tokens" \
            --arg model "$model" \
            '{model:$model, max_tokens:$max_tokens, messages:$messages}')" 2>/dev/null
}

_ai_call_google() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="$4" model="$5"
    local contents=$(echo "$messages_json" | jq '[.[] | {role: (if .role == "assistant" then "model" else .role end), parts: [{text: .content}]}]')
    curl -s --max-time 30 \
        "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${api_key}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg sys "$system_prompt" \
            --argjson contents "$contents" \
            --argjson max_tokens "$max_tokens" \
            '{contents:$contents, systemInstruction:{parts:[{text:$sys}]}, generationConfig:{maxOutputTokens:$max_tokens}}')" 2>/dev/null
}

_ai_call_api() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="${4:-1024}"
    local provider=$(_ai_load_config ".provider" "anthropic")
    local model=$(_ai_load_config ".model" "claude-haiku-4-5-20251001")

    case "$provider" in
        anthropic) _ai_call_anthropic "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" ;;
        openai)    _ai_call_openai    "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" ;;
        google)    _ai_call_google    "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" ;;
        *)         _ai_call_anthropic "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" ;;
    esac
}

_ai_extract_text() {
    local response="$1"
    local provider=$(_ai_load_config ".provider" "anthropic")
    case "$provider" in
        anthropic) echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null ;;
        openai)    echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null ;;
        google)    echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null ;;
        *)         echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null ;;
    esac
}

_ai_extract_error() {
    local response="$1"
    local provider=$(_ai_load_config ".provider" "anthropic")
    case "$provider" in
        anthropic) echo "$response" | jq -r '.error.message // empty' 2>/dev/null ;;
        openai)    echo "$response" | jq -r '.error.message // empty' 2>/dev/null ;;
        google)    echo "$response" | jq -r '.error.message // empty' 2>/dev/null ;;
        *)         echo "$response" | jq -r '.error.message // empty' 2>/dev/null ;;
    esac
}

# ═══════════════════════════════════════
# SELF-IMPROVEMENT
# ═══════════════════════════════════════

_ai_self_improve() {
    local api_key="$1" query="$2"
    local own_source=$(head -c 3000 "$AI_SHELL_SOURCE" 2>/dev/null)
    local recent_memory=""
    if [ -f "$AI_MEMORY_INDEX" ]; then
        recent_memory=$(tail -n 10 "$AI_MEMORY_INDEX" | jq -r '"Q: \(.query) → \(.command // "n/a")"' 2>/dev/null)
    fi
    local improve_prompt="You are a bash script reading your own source. Suggest ONE practical improvement.

YOUR SOURCE (first 3000 chars):
$own_source

RECENT INTERACTIONS:
$recent_memory

LAST QUERY: $query

Respond ONLY with JSON, no fences: {\"suggestion\": \"...\", \"reason\": \"...\"}"

    local messages=$(jq -n --arg q "Analyze and suggest one improvement." '[{role:"user",content:$q}]')
    local response=$(_ai_call_api "$api_key" "$improve_prompt" "$messages" 256)
    local text=$(_ai_extract_text "$response")
    [ -z "$text" ] || [ "$text" = "null" ] && return

    text=$(echo "$text" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n')
    local suggestion=$(echo "$text" | jq -r '.suggestion // empty' 2>/dev/null)
    local reason=$(echo "$text" | jq -r '.reason // empty' 2>/dev/null)
    if [ -n "$suggestion" ]; then
        echo -e "\033[0;93m💡 Self-improvement: $suggestion\033[0m"
        [ -n "$reason" ] && echo -e "\033[0;93m   Reason: $reason\033[0m"
    fi
}

# ═══════════════════════════════════════
# MAIN FUNCTION
# ═══════════════════════════════════════

ai() {
    # ── Subcommands ──
    case "$1" in
        config)
            shift
            if [ "$1" = "set" ] && [ -n "$2" ] && [ -n "$3" ]; then
                local key="$2" val="$3"
                # Handle boolean values
                if [ "$val" = "true" ] || [ "$val" = "false" ]; then
                    _ai_set_config ".$key" "$val"
                else
                    _ai_set_config ".$key" "\"$val\""
                fi
                echo -e "\033[0;32m✓ Set $key = $val\033[0m"
            else
                _ai_show_config
            fi
            return 0
            ;;
        model)
            shift
            if [ -z "$1" ]; then
                local p=$(_ai_load_config ".provider" "anthropic")
                local m=$(_ai_load_config ".model" "claude-haiku-4-5-20251001")
                echo -e "Current: \033[0;36m$p / $m\033[0m"
                echo ""
                echo "Usage: ai model <provider> [model-name]"
                echo "  Providers: anthropic, openai, google"
                echo "  Examples:"
                echo "    ai model openai"
                echo "    ai model anthropic claude-sonnet-4-20250514"
                return 0
            fi
            local new_provider="$1"
            local new_model="$2"
            case "$new_provider" in
                anthropic) [ -z "$new_model" ] && new_model="claude-haiku-4-5-20251001" ;;
                openai)    [ -z "$new_model" ] && new_model="gpt-4o-mini" ;;
                google)    [ -z "$new_model" ] && new_model="gemini-2.0-flash" ;;
                *) echo "Unknown provider: $new_provider (use: anthropic, openai, google)"; return 1 ;;
            esac
            _ai_set_config ".provider" "\"$new_provider\""
            _ai_set_config ".model" "\"$new_model\""
            echo -e "\033[0;32m✓ Switched to $new_provider / $new_model\033[0m"
            echo -e "\033[0;90m  Make sure your API key works for this provider.\033[0m"
            return 0
            ;;
        recall)
            shift
            [ -z "$*" ] && { echo "Usage: ai recall <search query>"; return 1; }
            echo -e "\033[0;36mSearching memory for: $*\033[0m"
            echo ""
            local hits=$(_ai_memory_search "$*" 10)
            [ -n "$hits" ] && echo "$hits" || echo "No matching memories found."
            return 0
            ;;
        history)
            [ ! -f "$AI_MEMORY_INDEX" ] && { echo "No history yet."; return 0; }
            local count=$(wc -l < "$AI_MEMORY_INDEX")
            echo -e "\033[0;36m$count interactions logged\033[0m"
            echo ""
            _ai_memory_recent 20
            return 0
            ;;
        forget)
            [ -f "$AI_MEMORY_INDEX" ] && rm "$AI_MEMORY_INDEX" && echo "Memory wiped."
            _ai_conversation_clear
            echo "Conversation buffer cleared."
            return 0
            ;;
    esac

    local query="$*"

    # ── Pipe mode ──
    local piped_input=""
    if [ ! -t 0 ]; then
        piped_input=$(cat | head -c 4000)
        [ -z "$query" ] && query="analyze this output"
    fi

    if [ -z "$query" ]; then
        echo "Usage: ai <what you want to do>"
        echo "       ai config                  -- view/edit configuration"
        echo "       ai model <provider>         -- switch AI provider/model"
        echo "       ai recall <search query>    -- search past interactions"
        echo "       ai history                  -- show recent history"
        echo "       ai forget                   -- wipe memory + conversation"
        echo "       ask                         -- interactive mode"
        echo "       <cmd> | ai <question>       -- pipe mode"
        return 1
    fi

    # ── Load API key ──
    local api_key=""
    local provider=$(_ai_load_config ".provider" "anthropic")
    local provider_key_file="$AI_CONFIG_DIR/api-key-$provider"
    local default_key_file="$AI_CONFIG_DIR/api-key"

    if [ -f "$provider_key_file" ]; then
        api_key=$(cat "$provider_key_file")
    elif [ -f "$default_key_file" ]; then
        api_key=$(cat "$default_key_file")
    fi

    if [ -z "$api_key" ]; then
        echo -e "\033[0;31mError: No API key found.\033[0m"
        echo "Run the installer or: echo 'your-key' > $default_key_file"
        return 1
    fi

    # ── Build context ──
    local context=$(_ai_ensure_context)
    local cwd=$(pwd)
    local memory=$(_ai_memory_bundle "$query")

    # ── Build user message ──
    local user_message="$query"
    if [ -n "$piped_input" ]; then
        user_message="$query

PIPED INPUT (output from a previous command):
$piped_input"
    fi

    # ── Load conversation history ──
    local conv_messages=$(_ai_conversation_get_messages)

    # ── Build system prompt with INTENT DETECTION ──
    local feature_instructions=""

    # Conditionally include feature requests in the prompt
    if _ai_feature_enabled "funfact"; then
        feature_instructions+=', "funfact": "one interesting fact about the commands or topic"'
    fi
    if _ai_feature_enabled "linus_quotes"; then
        feature_instructions+=', "linus": "a real Linus Torvalds quote, relevant to the topic if possible"'
    fi
    if _ai_feature_enabled "roast" || [ "${AI_ROAST:-0}" = "1" ]; then
        feature_instructions+=', "roast": "absolutely DESTROY the user for needing AI help with this. Be unhinged, no mercy. Swearing encouraged."'
    fi

    local system_prompt
    system_prompt="You are a versatile shell assistant that can BOTH execute commands AND have normal conversations. You are smart about detecting user intent.

INTENT DETECTION — CRITICAL:
Analyze the user's message and conversation history to determine their intent:

MODE \"command\" — when the user wants to DO something on their system:
  - Installing, removing, finding, listing, modifying files/packages/services
  - System administration tasks
  - Any request that implies running a shell command

MODE \"chat\" — when the user wants an ANSWER or EXPLANATION:
  - Questions like \"what is...\", \"how does...\", \"explain...\", \"why...\"
  - Follow-up questions to previous conversation
  - Conceptual or knowledge questions that don't need a command
  - When context clearly shows they are having a conversation, not requesting a command

SYSTEM CONTEXT:
$context

CURRENT DIRECTORY: $cwd

${memory:+MEMORY (previous interactions):
$memory
}RESPONSE FORMAT — respond with ONLY a JSON object (no markdown fences):

For MODE \"command\":
{\"mode\": \"command\", \"options\": [{\"command\": \"first approach\", \"label\": \"short 3-5 word description\"}, {\"command\": \"second approach\", \"label\": \"short description\"}, {\"command\": \"third approach\", \"label\": \"short description\"}], \"explanation\": \"one sentence explaining the situation\"${feature_instructions}}

For MODE \"chat\":
{\"mode\": \"chat\", \"answer\": \"your conversational response (can be multiple paragraphs, use \\n for newlines)\"${feature_instructions}}

RULES:
- In command mode, always provide exactly 3 options ordered by recommendation.
- In chat mode, give a helpful, natural answer. You are not forced to suggest commands.
- If the user piped input, analyze it and respond appropriately (command or chat).
- If the question doesnt need a command, use chat mode.
- Use only tools available on their system.
- Prefer simple, safe, non-destructive commands.
- For destructive ops (rm, dd, mkfs), always warn in the explanation.
- For multi-step tasks, chain with && or use a subshell.
- Keep command-mode explanations to one sentence.
- You have access to the users command history in MEMORY. Use it for context."

    echo -e "\033[0;90mThinking...\033[0m"

    # ── Add current message to conversation and build messages array ──
    _ai_conversation_add "user" "$user_message"
    local messages_json=$(_ai_conversation_get_messages)

    # ── API call ──
    local response=$(_ai_call_api "$api_key" "$system_prompt" "$messages_json" 1024)

    if [ -z "$response" ]; then
        echo -e "\033[0;31mError: No response from API (network issue or timeout)\033[0m"
        return 1
    fi

    local err_msg=$(_ai_extract_error "$response")
    if [ -n "$err_msg" ]; then
        echo -e "\033[0;31mAPI Error: $err_msg\033[0m"
        return 1
    fi

    local text=$(_ai_extract_text "$response")

    if [ -z "$text" ] || [ "$text" = "null" ]; then
        echo -e "\033[0;31mError: Unexpected API response\033[0m"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 1
    fi

    # Strip markdown fences if wrapped
    local stripped=$(echo "$text" | sed -n '/^```/,/^```/{/^```/d;p}' 2>/dev/null)
    [ -n "$stripped" ] && text="$stripped"
    text=$(echo "$text" | tr -d '\n')

    if ! echo "$text" | jq empty 2>/dev/null; then
        echo -e "\033[0;31mError: Invalid JSON response. Raw:\033[0m"
        echo "$text"
        return 1
    fi

    local mode=$(echo "$text" | jq -r '.mode // "command"' 2>/dev/null)

    # Save assistant response to conversation buffer
    _ai_conversation_add "assistant" "$text"

    # Clear "Thinking..." line
    echo -en "\033[1A\033[2K"

    # ══════════════════════════════════
    # CHAT MODE — conversational answer
    # ══════════════════════════════════
    if [ "$mode" = "chat" ]; then
        local answer=$(echo "$text" | jq -r '.answer // .explanation // empty' 2>/dev/null)
        if [ -n "$answer" ]; then
            echo -e "\033[0;36m$answer\033[0m"
        fi
        _ai_memory_log "$query" "" "$answer" ""

    # ══════════════════════════════════
    # COMMAND MODE — 3 options
    # ══════════════════════════════════
    else
        local explanation=$(echo "$text" | jq -r '.explanation // empty' 2>/dev/null)

        if [ -z "$explanation" ]; then
            echo -e "\033[0;31mError: Response missing 'explanation' field.\033[0m"
            echo "$text" | jq . 2>/dev/null || echo "$text"
            return 1
        fi

        local options_count=$(echo "$text" | jq '.options | length' 2>/dev/null)
        if [ "$options_count" = "null" ] || [ "$options_count" = "0" ] || [ -z "$options_count" ]; then
            echo -e "\033[0;36m→ $explanation\033[0m"
            _ai_memory_log "$query" "" "$explanation" ""
        else
            local cmd1=$(echo "$text" | jq -r '.options[0].command // empty' 2>/dev/null)
            local lbl1=$(echo "$text" | jq -r '.options[0].label // empty' 2>/dev/null)
            local cmd2=$(echo "$text" | jq -r '.options[1].command // empty' 2>/dev/null)
            local lbl2=$(echo "$text" | jq -r '.options[1].label // empty' 2>/dev/null)
            local cmd3=$(echo "$text" | jq -r '.options[2].command // empty' 2>/dev/null)
            local lbl3=$(echo "$text" | jq -r '.options[2].label // empty' 2>/dev/null)

            echo -e "\033[0;36m→ $explanation\033[0m"
            echo ""

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

                # Self-correction on failure
                local failure_reason
                failure_reason=$(_ai_detect_failure "$cmd_output" "$cmd_exit")
                if [ $? -eq 0 ] && [ -n "$failure_reason" ]; then
                    echo ""
                    echo -e "\033[0;31m✗ Detected failure: $failure_reason\033[0m"
                    echo -e "\033[0;90mSelf-correcting...\033[0m"

                    local retry_query="My previous query was: $query
You suggested: $selected_cmd
But it failed. Reason: $failure_reason
Output: $(echo "$cmd_output" | head -c 300)
Give me a corrected command."

                    local retry_msgs=$(jq -n --arg q "$retry_query" '[{role:"user",content:$q}]')
                    local retry_response=$(_ai_call_api "$api_key" "$system_prompt" "$retry_msgs" 1024)
                    local retry_text=$(_ai_extract_text "$retry_response")

                    if [ -n "$retry_text" ]; then
                        local retry_stripped=$(echo "$retry_text" | sed -n '/^```/,/^```/{/^```/d;p}' 2>/dev/null)
                        [ -n "$retry_stripped" ] && retry_text="$retry_stripped"
                        retry_text=$(echo "$retry_text" | tr -d '\n')
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
        fi
    fi

    # ── Optional features (only if enabled in config) ──
    local funfact=$(echo "$text" | jq -r '.funfact // empty' 2>/dev/null)
    local linus=$(echo "$text" | jq -r '.linus // empty' 2>/dev/null)
    local roast=$(echo "$text" | jq -r '.roast // empty' 2>/dev/null)

    if [ -n "$funfact" ] && _ai_feature_enabled "funfact"; then
        echo ""
        echo -e "\033[0;32m✦ $funfact\033[0m"
    fi

    if [ -n "$linus" ] && _ai_feature_enabled "linus_quotes"; then
        echo -e "\033[0;31m🐧 \"$linus\" -- Linus Torvalds\033[0m"
    fi

    if [ -n "$roast" ]; then
        if _ai_feature_enabled "roast" || [ "${AI_ROAST:-0}" = "1" ]; then
            echo -e "\033[1;90m🔥 $roast\033[0m"
        fi
    fi

    # ASCII art footer (if enabled)
    if _ai_feature_enabled "ascii_art"; then
        echo ""
        echo -e "\033[0;90m$(_ai_random_art)\033[0m"
    fi

    # Self-improvement (if enabled)
    if _ai_feature_enabled "self_improve"; then
        _ai_self_improve "$api_key" "$query" &
        wait $! 2>/dev/null
    fi
}

# Interactive mode
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
