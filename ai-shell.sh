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

AI_DEFAULT_PROVIDER="openai"

# ═══════════════════════════════════════
# MODEL CATALOG
# ═══════════════════════════════════════

_ai_default_model() {
    case "$1" in
        openai)    echo "gpt-6-sol" ;;
        anthropic) echo "claude-sonnet-5-5" ;;
        google)    echo "gemini-flash-latest" ;;
        *)         echo "gpt-6-sol" ;;
    esac
}

# Curated picks (checked 2026-10). `ai models` lists everything your key can use.
_ai_show_models() {
    local prov="$1"
    echo ""
    case "$prov" in
        openai)
            echo -e "  Recommended OpenAI models (\$ per 1M tokens in/out):"
            echo -e "    \033[0;32mgpt-6-sol\033[0m           \$2.00/\$10.00  — smart + fast with reasoning off (default)"
            echo -e "    gpt-6-luna          \$0.10/\$0.50   — nearly as fast, ~20x cheaper"
            echo -e "    gpt-5.4-mini        \$0.75/\$4.50   — fastest in testing, older generation"
            echo -e "    gpt-6.1-sol         \$2.00/\$10.00  — always reasons: smarter, ~3x slower"
            ;;
        anthropic)
            echo -e "  Recommended Anthropic models (\$ per 1M tokens in/out):"
            echo -e "    \033[0;32mclaude-sonnet-5-5\033[0m   \$2.00/\$10.00  — smart, thinking off for speed (default)"
            echo -e "    claude-haiku-4-5    \$1.00/\$5.00   — fastest, cheapest"
            echo -e "    claude-opus-5-5     \$4.00/\$20.00  — most capable Opus, always thinks (slower)"
            ;;
        google)
            echo -e "  Recommended Google models:"
            echo -e "    \033[0;32mgemini-flash-latest\033[0m       — alias for Google's newest Flash (default)"
            echo -e "    gemini-flash-lite-latest  — alias for the newest Flash-Lite (cheapest)"
            echo -e "    \033[0;90mRun 'ai models google' for pinned version IDs.\033[0m"
            ;;
    esac
    echo ""
}

# Price ($ per 1M tokens in/out) and a hint, for models we know about (checked 2026-10)
_ai_model_note() {
    case "$1" in
        gpt-6.1-sol)        echo "\$2/\$10|always reasons: smartest Sol, ~3x slower" ;;
        gpt-6-sol)          echo "\$2/\$10|smart + fast (recommended)" ;;
        gpt-6-luna)         echo "\$0.10/\$0.50|fast, ~20x cheaper" ;;
        gpt-6-astra)        echo "\$10/\$50|flagship, always reasons (slow)" ;;
        gpt-5.6-sol)        echo "\$5/\$30" ;;
        gpt-5.6-terra)      echo "\$2/\$12" ;;
        gpt-5.6-luna)       echo "\$0.20/\$1.20" ;;
        gpt-5.4-mini)       echo "\$0.75/\$4.50|fastest, older" ;;
        claude-sonnet-5-5)  echo "\$2/\$10|smart, thinking off (recommended)" ;;
        claude-opus-5-5)    echo "\$4/\$20|always thinks (slower)" ;;
        claude-fable-5-1|claude-fable-5) echo "\$10/\$50|most capable, always thinks (slow)" ;;
        claude-opus-5|claude-opus-4-[678]) echo "\$5/\$25" ;;
        claude-sonnet-5)    echo "\$2/\$10" ;;
        claude-sonnet-4-6)  echo "\$3/\$15" ;;
        claude-haiku-4-5*)  echo "\$1/\$5|fastest Claude" ;;
    esac
}

# Newest chat models for a provider, newest first. Cached for a day; pass "refresh" to refetch.
_ai_recent_models() {
    local provider="$1" n="${2:-6}" refresh="$3"
    local cache="$AI_CACHE_DIR/models-$provider.txt"
    if [ "$refresh" = "refresh" ] || [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +1440 2>/dev/null)" ]; then
        local key=$(_ai_get_api_key "$provider")
        [ -z "$key" ] && return 1
        mkdir -p "$AI_CACHE_DIR"
        local list
        case "$provider" in
            anthropic)
                list=$(curl -s --max-time 15 "https://api.anthropic.com/v1/models?limit=100" \
                    -H @<(printf 'x-api-key: %s\n' "$key") -H "anthropic-version: 2023-06-01" \
                    | jq -r '.data // [] | sort_by(.created_at) | reverse | .[].id' 2>/dev/null) ;;
            openai)
                # Only models that work on chat completions: no pro/codex/audio/etc, no dated snapshots
                list=$(curl -s --max-time 15 https://api.openai.com/v1/models \
                    -H @<(printf 'Authorization: Bearer %s\n' "$key") \
                    | jq -r '.data // [] | sort_by(-.created) | .[].id' 2>/dev/null \
                    | grep -E '^(gpt-[4-9]|o[0-9])' \
                    | grep -vE 'pro|codex|audio|realtime|tts|transcribe|image|search|instruct|live|chat-latest|-[0-9]{4}-[0-9]{2}-[0-9]{2}$') ;;
            google)
                list=$(_ai_list_models google "$key" | sort -rV) ;;
        esac
        [ -z "$list" ] && return 1
        echo "$list" > "$cache"
    fi
    head -n "$n" "$cache"
}

# Interactive model picker across providers (Alt+M, or `ai model` with no arguments)
_ai_pick_model() {
    local refresh="$1"
    local cur_p=$(_ai_load_config ".provider" "$AI_DEFAULT_PROVIDER")
    local cur_m=$(_ai_load_config ".model" "$(_ai_default_model "$cur_p")")
    local -a provs=() models=()
    local p m i=0 shown_current=0

    echo ""
    echo -e "\033[1mSwitch model\033[0m  \033[0;90m(current: $cur_p/$cur_m)\033[0m"
    for p in openai anthropic google; do
        if [ -z "$(_ai_get_api_key "$p")" ]; then
            [ "$p" != "google" ] && echo -e "\n  \033[0;90m$p: no key (save one to $AI_CONFIG_DIR/api-key-$p)\033[0m"
            continue
        fi
        local list=$(_ai_recent_models "$p" 6 "$refresh")
        # Keep the current model visible even if it isn't among the newest
        if [ "$p" = "$cur_p" ] && ! grep -qxF "$cur_m" <<< "$list"; then
            list+=$'\n'"$cur_m"
        fi
        [ -z "$list" ] && { echo -e "\n  \033[0;31m$p: could not fetch models\033[0m"; continue; }
        echo -e "\n  \033[1;36m$p\033[0m \033[0;90m(newest first)\033[0m"
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            provs+=("$p"); models+=("$m"); i=$((i + 1))
            local mark="  "
            [ "$p" = "$cur_p" ] && [ "$m" = "$cur_m" ] && mark="\033[0;32m●\033[0m "
            local note=$(_ai_model_note "$m")
            printf "  %b\033[1m%2d\033[0m  %-20s \033[0;90m%-13s %s\033[0m\n" "$mark" "$i" "$m" "${note%%|*}" "$([[ "$note" == *"|"* ]] && echo "${note#*|}")"
        done <<< "$list"
    done
    echo ""
    local choice
    read -r -p "Number, a model id, r to refresh, Enter to cancel: " choice < /dev/tty
    case "$choice" in
        "") echo "Unchanged."; return 0 ;;
        r|R) _ai_pick_model refresh; return ;;
    esac
    local new_p="" new_m=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
        new_p="${provs[$((choice - 1))]}"; new_m="${models[$((choice - 1))]}"
    else
        new_m="$choice"
        case "$new_m" in
            claude-*) new_p="anthropic" ;;
            gemini-*) new_p="google" ;;
            gpt-*|o[0-9]*) new_p="openai" ;;
            *) echo "Not a number on the list or a known model id."; return 1 ;;
        esac
    fi
    _ai_set_config ".provider" "\"$new_p\""
    _ai_set_config ".model" "\"$new_m\""
    echo -e "\033[0;32m✓ Now using $new_p/$new_m\033[0m"
}

# Last line of every answer: response time, model, how to switch
_ai_footer() {
    local start="$1" end="$2" provider="$3" model="$4" effort="$5"
    local secs=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }')
    local think=""
    [ "$effort" != "none" ] && think=" · reasoning: $effort"
    echo ""
    echo -e "\033[0;90m⏱ ${secs}s · $provider/$model$think · Alt+M to switch model\033[0m"
}

# ═══════════════════════════════════════
# CONFIG SYSTEM
# ═══════════════════════════════════════

_ai_load_config() {
    local key="$1"
    local default="$2"
    if [ -f "$AI_CONFIG_FILE" ]; then
        # Not `// empty`: that would turn an explicit false into the default
        local val=$(jq -r "$key | if . == null then empty else . end" "$AI_CONFIG_FILE" 2>/dev/null)
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

# The shared api-key file only counts for the provider its prefix belongs to
_ai_key_matches() {
    local provider="$1" key="$2"
    case "$key" in
        sk-ant-*) [ "$provider" = "anthropic" ] ;;
        sk-*)     [ "$provider" = "openai" ] ;;
        AI*)      [ "$provider" = "google" ] ;;
        *)        return 0 ;;
    esac
}

_ai_get_api_key() {
    local provider="$1"
    local provider_key_file="$AI_CONFIG_DIR/api-key-$provider"
    local default_key_file="$AI_CONFIG_DIR/api-key"
    if [ -f "$provider_key_file" ]; then
        tr -d '[:space:]' < "$provider_key_file"
    elif [ -f "$default_key_file" ] && _ai_key_matches "$provider" "$(tr -d '[:space:]' < "$default_key_file")"; then
        tr -d '[:space:]' < "$default_key_file"
    else
        case "$provider" in
            anthropic) echo "${ANTHROPIC_API_KEY:-}" ;;
            google)    echo "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ;;
            *)         echo "${OPENAI_API_KEY:-}" ;;
        esac
    fi
}

_ai_show_config() {
    if [ ! -f "$AI_CONFIG_FILE" ]; then
        echo "No config file found. Run the installer or use 'ai config set'."
        return 1
    fi
    echo -e "\033[1m┌─ AI Shelly Configuration ─┐\033[0m"
    echo ""
    local provider=$(_ai_load_config ".provider" "$AI_DEFAULT_PROVIDER")
    local model=$(_ai_load_config ".model" "$(_ai_default_model "$provider")")
    local effort=$(_ai_load_config ".reasoning_effort" "none")
    echo -e "  Provider:     \033[0;36m$provider\033[0m"
    echo -e "  Model:        \033[0;36m$model\033[0m"
    echo -e "  Reasoning:    \033[0;36m$effort\033[0m  (fixes use low, 'ai -t' uses medium)"
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

    # Tools the model might otherwise assume exist (or not)
    local tools=""
    for t in rg fd fzf bat eza jq yq docker podman kubectl git gh ncdu htop btop nvim tmux python3 node npm flatpak snap; do
        command -v "$t" &>/dev/null && tools+="$t "
    done
    ctx+="Installed tools: ${tools% }"
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

# Per-query context: where the user is and what just happened
_ai_live_context() {
    local last_cmd="$1" last_exit="$2"
    local ctx="Date: $(date '+%Y-%m-%d %H:%M %Z')"$'\n'
    ctx+="Current directory: $PWD"$'\n'
    local listing=$(ls -Ap 2>/dev/null | head -40 | tr '\n' ' ')
    [ -n "$listing" ] && ctx+="Directory contents (first 40): $listing"$'\n'
    local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ -n "$branch" ] && ctx+="Git repo, branch: $branch"$'\n'
    if [ -n "$last_cmd" ]; then
        ctx+="Previous shell command: $last_cmd (exit code $last_exit)"$'\n'
    fi
    echo "$ctx"
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

# Keyword search over memory in a single jq pass (scores by matching keywords)
_ai_memory_search() {
    local query="$1" max_results=${2:-5}
    [ ! -f "$AI_MEMORY_INDEX" ] && return
    jq -rn --arg q "$query" --argjson n "$max_results" '
        ["the","and","for","how","what","show","with","this","that","are","can","you",
         "all","from","into","does","why","get","use","make","need","want","there"] as $stop
        | ($q | ascii_downcase | [scan("[a-z0-9_.-]+")] | map(select(length > 2))
            | unique | map(select(. as $w | $stop | index($w) | not))) as $kw
        | [inputs | (tostring | ascii_downcase) as $l
            | {s: ([$kw[] | select(. as $k | $l | contains($k))] | length), e: .}
            | select(.s > 0)]
        | sort_by(-.s) | .[:$n][] | .e
        | "[\(.ts)] Q: \(.query) → $ \(if (.command // "") == "" then "n/a" else .command end)\n  \(.explanation)\n  Output: \(.output // "" | if length > 200 then .[:200] + "..." else . end)"
    ' "$AI_MEMORY_INDEX" 2>/dev/null
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
# SELF-CORRECTION & SAFETY
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

# Local backstop in case the model under-reports risk
_ai_looks_destructive() {
    echo "$1" | grep -qE '(^|[;&|[:space:]])(rm[[:space:]]+-[a-zA-Z]*[rf]|mkfs|dd[[:space:]].*of=/dev/|shred|wipefs|fdisk|parted|chmod[[:space:]]+-R[[:space:]]+[0-7]*[[:space:]]+/|chown[[:space:]]+-R.*[[:space:]]/([[:space:]]|$)|truncate[[:space:]]|>[[:space:]]*/dev/sd|git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[a-z]*f|push[[:space:]].*--force)|docker[[:space:]]+system[[:space:]]+prune)'
}

# Commands that change the calling shell's state must run in the current shell
_ai_needs_current_shell() {
    [[ "$1" =~ ^[[:space:]]*(cd|pushd|popd|export|unset|source|\.|alias|unalias|nvm|conda|deactivate|pyenv|direnv)([[:space:]]|$) ]]
}

# Full-screen/interactive programs need the real terminal, so their output isn't captured
_ai_needs_tty() {
    [[ "$1" =~ ^[[:space:]]*(sudo[[:space:]]+)?(htop|top|btop|atop|nvtop|ncdu|vim?|nvim|nano|emacs|less|more|man|ssh|tmux|screen|watch|mc|ranger|fzf|nmtui|alsamixer)([[:space:]]|$) ]]
}

# ═══════════════════════════════════════
# MULTI-PROVIDER API CALLS
# ═══════════════════════════════════════
# Effort levels used by this script: none (default, fastest), low (fixes), medium (ai -t).
# Each provider maps them onto whatever the model supports.

_ai_openai_effort() {
    local model="$1" effort="$2"
    case "$model" in
        gpt-4*|gpt-3.5*|*chat-latest*) echo "" ;;                       # not reasoning models
        gpt-5|gpt-5-20*|gpt-5-mini*|gpt-5-nano*|gpt-5-codex*)           # oldest GPT-5: no "none"
            [ "$effort" = "none" ] && echo "minimal" || echo "$effort" ;;
        o[0-9]*|gpt-6-astra*|gpt-6.1*|*-pro*)                            # always reason
            [ "$effort" = "none" ] && echo "low" || echo "$effort" ;;
        *) echo "$effort" ;;
    esac
}

_ai_call_openai() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="$4" model="$5" effort="$6"
    effort=$(_ai_openai_effort "$model" "$effort")
    local attempt response err supported
    for attempt in 1 2; do
        response=$(curl -s --max-time 90 https://api.openai.com/v1/chat/completions \
            -H "Content-Type: application/json" \
            -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
            -d "$(jq -n \
                --arg sys "$system_prompt" \
                --argjson msgs "$messages_json" \
                --argjson max_tokens "$max_tokens" \
                --arg model "$model" \
                --arg effort "$effort" \
                '{model:$model, max_completion_tokens:$max_tokens,
                  messages:([{role:"system",content:$sys}] + $msgs),
                  response_format:{type:"json_object"}}
                 + (if $effort == "" then {} else {reasoning_effort:$effort} end)')" 2>/dev/null)
        err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
        # Self-heal when the model rejects the effort level: use the lowest one it supports
        if [[ "$err" == *reasoning_effort* ]]; then
            supported=$(echo "$err" | grep -oE "Supported values are: '[a-z]+'" | grep -oE "'[a-z]+'" | tr -d "'")
            effort="$supported"
            continue
        fi
        break
    done
    echo "$response"
}

_ai_call_anthropic() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="$4" model="$5" effort="$6"
    # Thinking/effort controls differ per model generation
    local extra='{}'
    case "$model" in
        claude-3*|claude-haiku-4*|claude-*-4-5*|claude-*-4-1*|claude-*-4-2025*|claude-*-4-0*) ;;
        claude-sonnet-5-5*)
            if [ "$effort" = "none" ]; then
                extra='{"thinking":{"type":"between_tools"},"output_config":{"effort":"low"}}'
            else
                extra=$(jq -nc --arg e "$effort" '{output_config:{effort:$e}}')
            fi ;;
        claude-*)
            # Opus 5.5 / Fable can't disable thinking; low effort keeps it short
            [ "$effort" = "none" ] && effort="low"
            extra=$(jq -nc --arg e "$effort" '{output_config:{effort:$e}}') ;;
    esac
    local attempt response err
    for attempt in 1 2; do
        response=$(curl -s --max-time 90 https://api.anthropic.com/v1/messages \
            -H "content-type: application/json" \
            -H @<(printf 'x-api-key: %s\n' "$api_key") \
            -H "anthropic-version: 2023-06-01" \
            -d "$(jq -n \
                --arg system "$system_prompt" \
                --argjson messages "$messages_json" \
                --argjson max_tokens "$max_tokens" \
                --arg model "$model" \
                --argjson extra "$extra" \
                '{model:$model, max_tokens:$max_tokens, system:$system, messages:$messages} + $extra')" 2>/dev/null)
        err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
        if [ -n "$err" ] && [ "$extra" != '{}' ] && [[ "$err" == *thinking* || "$err" == *effort* || "$err" == *output_config* ]]; then
            extra='{}'
            continue
        fi
        break
    done
    echo "$response"
}

_ai_call_google() {
    local api_key="$1" system_prompt="$2" messages_json="$3" max_tokens="$4" model="$5" effort="$6"
    local contents=$(echo "$messages_json" | jq '[.[] | {role: (if .role == "assistant" then "model" else .role end), parts: [{text: .content}]}]')
    local thinking='null'
    case "$model" in
        gemini-2.5-flash*)
            case "$effort" in none) thinking='{"thinkingBudget":0}' ;; low) thinking='{"thinkingBudget":1024}' ;; *) thinking='{"thinkingBudget":4096}' ;; esac ;;
        gemini-2*|gemini-1*) ;;
        gemini-*)
            case "$effort" in none) thinking='{"thinkingLevel":"minimal"}' ;; *) thinking=$(jq -nc --arg e "$effort" '{thinkingLevel:$e}') ;; esac ;;
    esac
    local attempt response err
    for attempt in 1 2; do
        response=$(curl -s --max-time 90 \
            "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
            -H "Content-Type: application/json" \
            -H @<(printf 'x-goog-api-key: %s\n' "$api_key") \
            -d "$(jq -n \
                --arg sys "$system_prompt" \
                --argjson contents "$contents" \
                --argjson max_tokens "$max_tokens" \
                --argjson thinking "$thinking" \
                '{contents:$contents, systemInstruction:{parts:[{text:$sys}]},
                  generationConfig:({maxOutputTokens:$max_tokens, responseMimeType:"application/json"}
                    + (if $thinking == null then {} else {thinkingConfig:$thinking} end))}')" 2>/dev/null)
        err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
        if [ -n "$err" ] && [ "$thinking" != 'null' ] && [[ "$err" == *hinking* ]]; then
            thinking='null'
            continue
        fi
        break
    done
    echo "$response"
}

# Usage: _ai_call_api provider model api_key system_prompt messages_json [effort] [max_tokens]
_ai_call_api() {
    local provider="$1" model="$2" api_key="$3" system_prompt="$4" messages_json="$5"
    local effort="${6:-none}" max_tokens="${7:-8192}"
    case "$provider" in
        anthropic) _ai_call_anthropic "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" "$effort" ;;
        google)    _ai_call_google    "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" "$effort" ;;
        *)         _ai_call_openai    "$api_key" "$system_prompt" "$messages_json" "$max_tokens" "$model" "$effort" ;;
    esac
}

_ai_extract_text() {
    local provider="$1" response="$2"
    case "$provider" in
        # Thinking-capable Claude models can return thinking blocks before the text
        anthropic) echo "$response" | jq -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null ;;
        google)    echo "$response" | jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")' 2>/dev/null ;;
        *)         echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null ;;
    esac
}

_ai_extract_error() {
    local provider="$1" response="$2"
    local err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -z "$err" ] && [ "$provider" = "anthropic" ]; then
        [ "$(echo "$response" | jq -r '.stop_reason // empty' 2>/dev/null)" = "refusal" ] && err="The model declined this request."
    fi
    echo "$err"
}

# Pull a JSON object out of model text (handles fences, chatter, raw newlines) and print it compact
_ai_parse_json() {
    local text="$1"
    if echo "$text" | jq -ce 'type == "object"' >/dev/null 2>&1; then
        echo "$text" | jq -c .
        return 0
    fi
    [[ "$text" == *"{"*"}"* ]] || return 1
    text="{${text#*\{}"
    text="${text%\}*}}"
    echo "$text" | jq -c . 2>/dev/null && return 0
    echo "$text" | tr '\n' ' ' | jq -c . 2>/dev/null
}

# List models available to your key, straight from the provider
_ai_list_models() {
    local provider="$1" api_key="$2"
    case "$provider" in
        anthropic)
            curl -s --max-time 20 "https://api.anthropic.com/v1/models?limit=100" \
                -H @<(printf 'x-api-key: %s\n' "$api_key") -H "anthropic-version: 2023-06-01" \
                | jq -r '.data[]?.id' ;;
        google)
            curl -s --max-time 20 "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200" \
                -H @<(printf 'x-goog-api-key: %s\n' "$api_key") \
                | jq -r '.models[]? | select(.supportedGenerationMethods | index("generateContent")) | .name | ltrimstr("models/")' \
                | grep -E '^gemini' | grep -vE 'image|tts|audio|embedding|live' | sort -V ;;
        *)
            curl -s --max-time 20 https://api.openai.com/v1/models \
                -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
                | jq -r '.data[]?.id' | grep -E '^(gpt-[4-9]|o[0-9])' \
                | grep -vE 'audio|realtime|tts|transcribe|image|search|instruct|codex|live|-[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -V ;;
    esac
}

# ═══════════════════════════════════════
# SELF-IMPROVEMENT
# ═══════════════════════════════════════

_ai_self_improve() {
    local provider="$1" model="$2" api_key="$3" query="$4"
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

Respond ONLY with JSON: {\"suggestion\": \"...\", \"reason\": \"...\"}"

    local messages=$(jq -n --arg q "Analyze and suggest one improvement." '[{role:"user",content:$q}]')
    local response=$(_ai_call_api "$provider" "$model" "$api_key" "$improve_prompt" "$messages" none 1024)
    local text=$(_ai_parse_json "$(_ai_extract_text "$provider" "$response")") || return
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
    # Must be first: exit status of whatever the user ran before `ai`
    local last_exit=$?
    local last_cmd=""
    if [[ $- == *i* ]]; then
        last_cmd=$(fc -ln -2 -2 2>/dev/null | sed 's/^[[:space:]]*//')
        [[ "$last_cmd" =~ ^(ai|ask)([[:space:]]|$) ]] && last_cmd=""
    fi

    # ── Subcommands ──
    case "$1" in
        config)
            shift
            if [ "$1" = "set" ] && [ -n "$2" ] && [ -n "$3" ]; then
                local key="$2" val="$3"
                # Store booleans and numbers as JSON types
                if [[ "$val" =~ ^(true|false|[0-9]+)$ ]]; then
                    _ai_set_config ".$key" "$val"
                else
                    _ai_set_config ".$key" "$(jq -n --arg v "$val" '$v')"
                fi
                echo -e "\033[0;32m✓ Set $key = $val\033[0m"
            else
                _ai_show_config
            fi
            return 0
            ;;
        model)
            shift
            if [ -z "$1" ] && [ -t 1 ]; then
                _ai_pick_model
                return
            fi
            if [ -z "$1" ]; then
                local p=$(_ai_load_config ".provider" "$AI_DEFAULT_PROVIDER")
                local m=$(_ai_load_config ".model" "$(_ai_default_model "$p")")
                echo -e "Current: \033[0;36m$p / $m\033[0m"
                _ai_show_models "$p"
                echo -e "  \033[0;90mUsage:\033[0m"
                echo -e "  \033[0;90m  ai model <provider>          — switch provider (use default model)\033[0m"
                echo -e "  \033[0;90m  ai model <provider> <model>  — switch to specific model\033[0m"
                echo -e "  \033[0;90m  ai models [provider]         — list every model your key can use\033[0m"
                echo -e "  \033[0;90m  Providers: openai, anthropic, google\033[0m"
                return 0
            fi
            local new_provider="$1"
            local new_model="$2"
            case "$new_provider" in
                anthropic|openai|google) ;;
                *) echo "Unknown provider: $new_provider (use: anthropic, openai, google)"; return 1 ;;
            esac
            if [ -z "$new_model" ]; then
                _ai_show_models "$new_provider"
                new_model=$(_ai_default_model "$new_provider")
                echo -e "  \033[0;90mDefaulting to: $new_model\033[0m"
            fi
            _ai_set_config ".provider" "\"$new_provider\""
            _ai_set_config ".model" "\"$new_model\""
            echo -e "\033[0;32m✓ Switched to $new_provider / $new_model\033[0m"
            [ -z "$(_ai_get_api_key "$new_provider")" ] && \
                echo -e "\033[0;33m  No key found. Save one to $AI_CONFIG_DIR/api-key-$new_provider\033[0m"
            return 0
            ;;
        models)
            shift
            local p="${1:-$(_ai_load_config ".provider" "$AI_DEFAULT_PROVIDER")}"
            local k=$(_ai_get_api_key "$p")
            [ -z "$k" ] && { echo "No API key for $p."; return 1; }
            echo -e "\033[0;36mModels available to your $p key:\033[0m"
            _ai_list_models "$p" "$k" | column -c "${COLUMNS:-100}"
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

    # Locale-proof: EPOCHREALTIME uses the locale's decimal separator
    local t_start=$(LC_ALL=C date +%s.%N)

    # ── Think harder for this one query ──
    local provider=$(_ai_load_config ".provider" "$AI_DEFAULT_PROVIDER")
    local model=$(_ai_load_config ".model" "$(_ai_default_model "$provider")")
    local effort=$(_ai_load_config ".reasoning_effort" "none")
    if [ "$1" = "-t" ] || [ "$1" = "--think" ]; then
        shift
        effort="medium"
    fi

    local query="$*"

    # ── Pipe mode ──
    local piped_input=""
    if [ ! -t 0 ]; then
        piped_input=$(cat | head -c 8000)
        [ -z "$query" ] && query="analyze this output"
    fi

    if [ -z "$query" ]; then
        echo "Usage: ai <what you want to do>"
        echo "       ai -t <question>            -- think harder (slower, smarter)"
        echo "       ai config                   -- view/edit configuration"
        echo "       ai model <provider> [model] -- switch AI provider/model"
        echo "       ai models [provider]        -- list models your key can use"
        echo "       ai recall <search query>    -- search past interactions"
        echo "       ai history                  -- show recent history"
        echo "       ai forget                   -- wipe memory + conversation"
        echo "       Alt+M  or  ai model         -- pick a model from the newest available"
        echo "       ask                         -- interactive mode"
        echo "       <cmd> | ai <question>       -- pipe mode"
        return 1
    fi

    # ── Load API key ──
    local api_key=$(_ai_get_api_key "$provider")
    if [ -z "$api_key" ]; then
        echo -e "\033[0;31mError: No API key found for $provider.\033[0m"
        echo "Run the installer or: echo 'your-key' > $AI_CONFIG_DIR/api-key-$provider"
        return 1
    fi

    # ── Build context ──
    local context=$(_ai_ensure_context)
    local live_context=$(_ai_live_context "$last_cmd" "$last_exit")
    local memory=$(_ai_memory_bundle "$query")

    # ── Build user message ──
    local user_message="$query"
    if [ -n "$piped_input" ]; then
        user_message="$query

PIPED INPUT (output from a previous command):
$piped_input"
    fi

    # ── Build system prompt with INTENT DETECTION ──
    local feature_instructions=""

    # Conditionally include feature requests in the prompt
    if _ai_feature_enabled "funfact"; then
        feature_instructions+=', "funfact": "one interesting fact about the commands or topic"'
    fi
    if _ai_feature_enabled "linus_quotes"; then
        feature_instructions+=', "linus": "a real Linus Torvalds quote, relevant to the topic if possible (quote text only, no attribution)"'
    fi
    if _ai_feature_enabled "roast" || [ "${AI_ROAST:-0}" = "1" ]; then
        feature_instructions+=', "roast": "absolutely DESTROY the user for needing AI help with this. Be unhinged, no mercy. Swearing encouraged."'
    fi

    # Stable instructions first, per-query context last (lets providers cache the prefix)
    local system_prompt
    system_prompt="You are an expert shell assistant that can BOTH produce commands AND have normal conversations. You are smart about detecting user intent.

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

RESPONSE FORMAT — respond with ONLY a JSON object:

For MODE \"command\":
{\"mode\": \"command\", \"options\": [{\"command\": \"best approach\", \"label\": \"short 3-5 word description\", \"risk\": \"safe|caution|danger\"}, {\"command\": \"second approach\", \"label\": \"...\", \"risk\": \"...\"}, {\"command\": \"third approach\", \"label\": \"...\", \"risk\": \"...\"}], \"explanation\": \"one sentence explaining the situation\"${feature_instructions}}

For MODE \"chat\":
{\"mode\": \"chat\", \"answer\": \"your conversational response (can be multiple paragraphs, use \\n for newlines)\"${feature_instructions}}

RULES:
- In command mode, provide 3 genuinely different options ordered by recommendation (best first).
- Each command must work as-is when pasted into this user's shell: correct flags for their OS and tool versions, quote paths, no placeholders like <file> unless unavoidable.
- risk: \"safe\" = read-only or trivially reversible; \"caution\" = changes state (installs, edits, restarts); \"danger\" = deletes data, overwrites disks, or is hard to undo.
- In chat mode, give a helpful, natural, concise answer. You are not forced to suggest commands.
- Output is printed raw in a terminal: no Markdown bold, italics or headers (backticks around commands are fine).
- If the user piped input, analyze it and respond appropriately (command or chat).
- If the user refers to \"that\", \"it\", or an error without details, they likely mean the PREVIOUS SHELL COMMAND in context.
- Use only tools available on their system. Prefer simple, safe, non-destructive commands.
- For destructive ops (rm, dd, mkfs), always warn in the explanation.
- For multi-step tasks, chain with && or use a subshell.
- Keep command-mode explanations to one sentence.
- You have access to the user's command history in MEMORY. Use it for context.

SYSTEM CONTEXT:
$context

CURRENT CONTEXT:
$live_context
${memory:+
MEMORY (previous interactions):
$memory}"

    echo -e "\033[0;90mThinking...\033[0m"

    # ── Add current message to conversation and build messages array ──
    _ai_conversation_add "user" "$user_message"
    local messages_json=$(_ai_conversation_get_messages)

    # ── API call ──
    local response=$(_ai_call_api "$provider" "$model" "$api_key" "$system_prompt" "$messages_json" "$effort")
    local t_end=$(LC_ALL=C date +%s.%N)

    if [ -z "$response" ]; then
        echo -e "\033[0;31mError: No response from API (network issue or timeout)\033[0m"
        return 1
    fi

    local err_msg=$(_ai_extract_error "$provider" "$response")
    if [ -n "$err_msg" ]; then
        echo -e "\033[0;31mAPI Error: $err_msg\033[0m"
        return 1
    fi

    local raw_text=$(_ai_extract_text "$provider" "$response")
    if [ -z "$raw_text" ] || [ "$raw_text" = "null" ]; then
        echo -e "\033[0;31mError: Unexpected API response\033[0m"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 1
    fi

    local text
    if ! text=$(_ai_parse_json "$raw_text"); then
        echo -e "\033[0;31mError: Invalid JSON response. Raw:\033[0m"
        echo "$raw_text"
        return 1
    fi

    # Save assistant response to conversation buffer
    _ai_conversation_add "assistant" "$text"

    # ── Unpack response in one jq call ──
    local mode="" answer="" explanation="" funfact="" linus="" roast=""
    local -a cmds=() labels=() risks=()
    eval "$(echo "$text" | jq -r '
        @sh "mode=\(.mode // "command" | tostring)",
        @sh "answer=\(.answer // .explanation // "" | tostring)",
        @sh "explanation=\(.explanation // "" | tostring)",
        @sh "funfact=\(.funfact // "" | tostring)",
        @sh "linus=\(.linus // "" | tostring)",
        @sh "roast=\(.roast // "" | tostring)",
        ((.options // []) | if type == "array" then . else [] end
            | map(select(type == "object" and (.command // "") != "")) | .[:3]) as $o
        | "cmds=(\($o | map(.command | tostring) | @sh))",
          "labels=(\($o | map(.label // "" | tostring) | @sh))",
          "risks=(\($o | map(.risk // "safe" | tostring) | @sh))"
    ')"

    # Clear "Thinking..." line
    echo -en "\033[1A\033[2K"

    # ══════════════════════════════════
    # CHAT MODE — conversational answer
    # ══════════════════════════════════
    if [ "$mode" = "chat" ]; then
        if [ -n "$answer" ]; then
            echo -e "\033[0;36m$answer\033[0m"
        fi
        _ai_memory_log "$query" "" "$answer" ""

    # ══════════════════════════════════
    # COMMAND MODE — pick an option
    # ══════════════════════════════════
    else
        if [ -z "$explanation" ] && [ ${#cmds[@]} -eq 0 ]; then
            echo -e "\033[0;31mError: Response had no explanation or commands.\033[0m"
            echo "$text" | jq .
            return 1
        fi

        [ -n "$explanation" ] && echo -e "\033[0;36m→ $explanation\033[0m"

        if [ ${#cmds[@]} -eq 0 ]; then
            _ai_memory_log "$query" "" "$explanation" ""
        else
            echo ""
            local -a colors=("1;32" "1;34" "1;35")
            local i n=${#cmds[@]}
            for ((i = 0; i < n; i++)); do
                local tag=""
                if [ "${risks[$i]}" = "danger" ] || _ai_looks_destructive "${cmds[$i]}"; then
                    risks[$i]="danger"
                    tag=" \033[1;31m⚠ destructive\033[0m"
                elif [ "${risks[$i]}" = "caution" ]; then
                    tag=" \033[0;33m(changes system)\033[0m"
                fi
                echo -e "  \033[${colors[$i]}m[$((i + 1))]\033[0m \033[0;${colors[$i]#1;}m${labels[$i]}\033[0m$tag"
                echo -e "      \033[1;33m\$ ${cmds[$i]}\033[0m"
            done
            echo ""

            local choice range="1"
            [ "$n" -ge 2 ] && range="1-$n"
            # Read from the terminal so selection works in pipe mode too
            read -r -p "Pick [$range] or q to cancel: " choice < /dev/tty

            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
                echo "Cancelled."
                _ai_memory_log "$query" "" "$explanation" ""
                _ai_footer "$t_start" "$t_end" "$provider" "$model" "$effort"
                return 0
            fi
            local selected_cmd="${cmds[$((choice - 1))]}"
            local selected_risk="${risks[$((choice - 1))]}"

            if [ "$selected_risk" = "danger" ]; then
                local confirm
                read -r -p $'\033[1;31mThis can destroy data. Type "yes" to run it: \033[0m' confirm < /dev/tty
                if [ "$confirm" != "yes" ]; then
                    echo "Cancelled."
                    _ai_footer "$t_start" "$t_end" "$provider" "$model" "$effort"
                    return 0
                fi
            fi

            local cmd_output="" cmd_exit=0
            _ai_run_command "$selected_cmd"

            # Self-correction on failure: same conversation, a bit more reasoning
            local failure_reason
            failure_reason=$(_ai_detect_failure "$cmd_output" "$cmd_exit")
            if [ $? -eq 0 ] && [ -n "$failure_reason" ]; then
                echo ""
                echo -e "\033[0;31m✗ Detected failure: $failure_reason\033[0m"
                echo -e "\033[0;90mSelf-correcting...\033[0m"

                local retry_query="I ran: $selected_cmd
It failed. Reason: $failure_reason
Output (truncated):
$(echo "$cmd_output" | tail -c 1500)
Diagnose what went wrong and give me a corrected command (command mode, best fix first)."

                local retry_msgs=$(jq -c --arg q "$retry_query" '. + [{role:"user",content:$q}]' <<< "$(_ai_conversation_get_messages)")
                local fix_effort=$(_ai_load_config ".fix_reasoning_effort" "low")
                local retry_response=$(_ai_call_api "$provider" "$model" "$api_key" "$system_prompt" "$retry_msgs" "$fix_effort")
                local retry_text=$(_ai_parse_json "$(_ai_extract_text "$provider" "$retry_response")")

                echo -en "\033[1A\033[2K"
                local retry_cmd="" retry_expl="" retry_risk="safe"
                if [ -n "$retry_text" ]; then
                    retry_cmd=$(echo "$retry_text" | jq -r '.options[0].command // empty' 2>/dev/null)
                    retry_expl=$(echo "$retry_text" | jq -r '.explanation // .answer // empty' 2>/dev/null)
                    retry_risk=$(echo "$retry_text" | jq -r '.options[0].risk // "safe"' 2>/dev/null)
                fi

                if [ -n "$retry_cmd" ]; then
                    echo -e "\033[0;36m→ Fix: $retry_expl\033[0m"
                    echo -e "\033[1;33m  \$ $retry_cmd\033[0m"
                    echo ""
                    local retry_choice prompt="Run corrected command? [Y/n] "
                    if [ "$retry_risk" = "danger" ] || _ai_looks_destructive "$retry_cmd"; then
                        prompt=$'\033[1;31m⚠ Destructive. Type "yes" to run it: \033[0m'
                        read -r -p "$prompt" retry_choice < /dev/tty
                        [ "$retry_choice" = "yes" ] && retry_choice="y" || retry_choice="n"
                    else
                        read -r -p "$prompt" retry_choice < /dev/tty
                    fi
                    if [[ "$retry_choice" =~ ^[Yy]?$ ]]; then
                        _ai_run_command "$retry_cmd"
                        selected_cmd="$retry_cmd"
                    fi
                elif [ -n "$retry_expl" ]; then
                    echo -e "\033[0;36m→ $retry_expl\033[0m"
                fi
            fi

            _ai_memory_log "$query" "$selected_cmd" "$explanation" "$cmd_output"
        fi
    fi

    # ── Optional features (only if enabled in config) ──
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
        _ai_self_improve "$provider" "$model" "$api_key" "$query"
    fi

    _ai_footer "$t_start" "$t_end" "$provider" "$model" "$effort"
}

# Runs a chosen command, streaming its output live. Sets cmd_output and cmd_exit in the caller.
_ai_run_command() {
    local cmd="$1"
    echo ""
    echo -e "\033[1;33m  \$ $cmd\033[0m"
    echo ""
    if _ai_needs_current_shell "$cmd"; then
        # cd/export/source must affect the user's shell, so no subshell or capture
        eval "$cmd"
        cmd_exit=$?
        cmd_output=""
    elif _ai_needs_tty "$cmd"; then
        ( eval "$cmd" )
        cmd_exit=$?
        cmd_output=""
    else
        local out_file=$(mktemp)
        ( eval "$cmd" ) 2>&1 | tee "$out_file"
        cmd_exit=${PIPESTATUS[0]}
        cmd_output=$(tail -c 4000 "$out_file")
        rm -f "$out_file"
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
    # Split on whitespace without globbing so subcommands still work and quotes survive
    local -a words
    read -r -a words <<< "$raw_query"
    ai "${words[@]}"
}

# Key-binding entry point. Readline holds the terminal in raw mode (no echo, Enter sends CR
# with no newline translation), so `read` would never see Enter. Restore normal mode for
# the picker, then hand the terminal back to readline.
_ai_pick_model_key() {
    local saved
    saved=$(stty -g < /dev/tty 2>/dev/null)
    stty sane < /dev/tty 2>/dev/null
    echo ""
    _ai_pick_model
    [ -n "$saved" ] && stty "$saved" < /dev/tty 2>/dev/null
}

# Alt+M opens the model picker (interactive bash only)
if [[ $- == *i* ]] && [ -n "$BASH_VERSION" ]; then
    bind -x '"\em": _ai_pick_model_key' 2>/dev/null
fi
