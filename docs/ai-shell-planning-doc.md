# `ai` — Natural Language Shell Assistant

## Concept

A lightweight bash function/script that lets you type `ai <natural language>` in any terminal and get back executable shell commands (or direct answers) from Claude Haiku. It knows your exact system configuration and acts as a translator between plain English and Linux commands.

```bash
$ ai show me what's eating my ram
# Claude returns: ps aux --sort=-%mem | head -15
# Prompt: Run it? [Y/n]

$ ai is my nvidia driver loaded
# Claude returns: lsmod | grep nvidia && nvidia-smi -q -d POWER
# Prompt: Run it? [Y/n]

$ ai add a cron job to clear /tmp every sunday at 3am
# Claude returns the crontab command, explains it, asks to run
```

---

## Architecture

Dead simple — one bash script, no dependencies beyond `curl` and `jq`.

```
User types: ai <query>
     │
     ▼
Bash function grabs system context (cached)
     │
     ▼
Sends prompt + context to Anthropic API (Haiku)
     │
     ▼
Haiku returns a command + explanation
     │
     ▼
User confirms → command executes in current shell
```

---

## Components

### 1. The `ai` bash function

Lives in `~/.bashrc` (or `~/.ai-shell.sh` sourced from bashrc). Needs to be a function (not a standalone script) so it can execute commands in the **current shell context** — meaning `cd`, `export`, and other builtins actually work.

### 2. System context collector

A cached snapshot of the system so Haiku knows what it's working with. Regenerated once per boot (or daily). Cached to `~/.cache/ai-shell/system-context.txt`.

Collects:
- OS / distro / kernel version
- CPU, RAM, GPU
- Package manager (apt, dnf, pacman, etc.)
- Shell type and version
- Installed tools (docker, git, systemctl, etc.)
- Current user and groups

### 3. API call

Single `curl` POST to `https://api.anthropic.com/v1/messages` using Haiku (`claude-haiku-4-5-20251001`). API key stored in `~/.config/ai-shell/api-key` (chmod 600).

### 4. Response handler

Parses the response, displays the command and explanation, prompts for confirmation before executing.

---

## Implementation Plan

### File Structure

```
~/.config/ai-shell/
├── api-key              # Anthropic API key (chmod 600)
└── config               # Optional: model override, auto-run, etc.

~/.cache/ai-shell/
├── system-context.txt   # Cached system info
└── history.log          # Optional: log of past queries

~/.ai-shell.sh           # The main script, sourced from .bashrc
```

### Step 1: System context script

```bash
generate_system_context() {
    cat <<EOF
System: $(uname -srm)
Distro: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
RAM: $(free -h | awk '/Mem:/{print $2}')
GPU: $(lspci | grep -i 'vga\|3d' | cut -d: -f3 | xargs)
Shell: $SHELL ($BASH_VERSION)
User: $(whoami) groups: $(groups)
Package manager: $(which apt dnf pacman zypper 2>/dev/null | head -1 | xargs basename)
Init: $(ps -p 1 -o comm= 2>/dev/null)
Kernel params: $(cat /proc/cmdline)
EOF
}
```

Cache it so every `ai` call doesn't re-run all those commands:

```bash
CONTEXT_CACHE="$HOME/.cache/ai-shell/system-context.txt"
if [ ! -f "$CONTEXT_CACHE" ] || [ "$(date +%Y%m%d)" != "$(date -r "$CONTEXT_CACHE" +%Y%m%d)" ]; then
    mkdir -p "$(dirname "$CONTEXT_CACHE")"
    generate_system_context > "$CONTEXT_CACHE"
fi
```

### Step 2: The `ai` function

```bash
ai() {
    local query="$*"
    if [ -z "$query" ]; then
        echo "Usage: ai <what you want to do>"
        return 1
    fi

    local api_key=$(cat ~/.config/ai-shell/api-key)
    local context=$(cat ~/.cache/ai-shell/system-context.txt)
    local cwd=$(pwd)

    local system_prompt="You are a Linux shell assistant. The user will ask you to do something on their system. You know their exact system config.

SYSTEM CONTEXT:
$context

CURRENT DIRECTORY: $cwd

RULES:
- Return a JSON object with two fields: \"command\" (the shell command to run) and \"explanation\" (one sentence explaining what it does).
- If the user is asking a question that doesn't need a command, set command to null and put the answer in explanation.
- Use only tools available on their system. No sudo unless necessary.
- Prefer simple, safe commands. Never run anything destructive without warning.
- For multi-step tasks, chain with && or provide a small script."

    local response=$(curl -s https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg model "claude-haiku-4-5-20251001" \
            --arg system "$system_prompt" \
            --arg query "$query" \
            '{
                model: $model,
                max_tokens: 512,
                system: $system,
                messages: [{role: "user", content: $query}]
            }')")

    # Parse response
    local text=$(echo "$response" | jq -r '.content[0].text')
    local command=$(echo "$text" | jq -r '.command // empty' 2>/dev/null)
    local explanation=$(echo "$text" | jq -r '.explanation // empty' 2>/dev/null)

    # If JSON parsing failed, just show raw response
    if [ -z "$explanation" ]; then
        echo "$text"
        return
    fi

    echo -e "\033[0;36m→ $explanation\033[0m"

    if [ -n "$command" ] && [ "$command" != "null" ]; then
        echo -e "\033[1;33m\$ $command\033[0m"
        read -p "Run it? [Y/n] " confirm
        if [[ "$confirm" =~ ^[Yy]?$ ]]; then
            eval "$command"
        fi
    fi
}
```

### Step 3: Installation (one-liner)

```bash
# Source it from bashrc:
echo 'source ~/.ai-shell.sh' >> ~/.bashrc
source ~/.bashrc
```

---

## Optional Enhancements (Later)

| Feature | Description |
|---------|-------------|
| **Conversation mode** | `ai -c` opens a multi-turn chat that remembers context |
| **Auto-run mode** | `ai -y <query>` skips confirmation for safe commands |
| **Pipe support** | `dmesg \| ai what does this mean` — pipe output as context |
| **History** | Log queries and commands to `~/.cache/ai-shell/history.log` |
| **Cost tracking** | Track token usage per call, show monthly spend |
| **Sudo awareness** | Detect when sudo is needed, warn explicitly |
| **Tab completion** | Bash completions for common prefixes |
| **Streaming** | Stream the response for faster feel (needs more complex curl) |

---

## Cost Estimate

Haiku 4.5 pricing:
- Input: $0.80 / 1M tokens
- Output: $0.40 / 1M tokens (cache miss not relevant here since we're not caching prompts on Anthropic's side)

System context + query ≈ ~400 tokens input, ~100 tokens output per call.

**Cost per query: ~$0.0004** (less than a tenth of a cent).

1,000 queries/month ≈ **$0.40/month**.

---

## Security Considerations

- API key stored in `~/.config/ai-shell/api-key` with `chmod 600`
- Never auto-execute without user confirmation (unless `-y` flag)
- The `eval` in the function is the main risk — mitigated by showing the command first and requiring confirmation
- Never send file contents to the API — only system metadata and the user's query
- Could add a command blocklist (rm -rf /, dd, mkfs, etc.) as an extra safety layer

---

## Dependencies

- `curl` — already installed
- `jq` — `sudo apt install jq` (likely already installed)
- That's it. No Python, no Node, no venv.

---

## Getting Started

```bash
# 1. Get an API key from https://console.anthropic.com/
# 2. Set it up:
mkdir -p ~/.config/ai-shell
echo "sk-ant-your-key-here" > ~/.config/ai-shell/api-key
chmod 600 ~/.config/ai-shell/api-key

# 3. Install jq if not present:
sudo apt install jq

# 4. Create the script (we'll build it together)
# 5. Source it and go:
ai what kernel am I running
```
