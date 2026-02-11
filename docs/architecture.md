# AI Shelly — Architecture & Technical Design

## Concept

A cross-platform natural language shell assistant that works natively on **Linux, macOS, and Windows PowerShell**. Type `ai <natural language>` and get back executable commands or conversational answers. It detects your system, remembers your history, and knows when to give you a command vs. just answer a question.

```
# Linux / macOS (bash/zsh)
$ ai show me what's eating my ram
→ ps aux --sort=-%mem | head -15

# Windows (PowerShell)
PS> ai show me what's eating my ram
→ Get-Process | Sort-Object WorkingSet64 -Descending | Select -First 15
```

---

## Architecture

```
User types: ai <query>
     │
     ▼
Load config.json (features, provider, model)
     │
     ▼
Load conversation buffer (last N exchanges)
     │
     ▼
Generate system context (OS, CPU, RAM, shell — cached daily)
     │
     ▼
Build system prompt with intent detection rules
     │
     ▼
Send multi-turn messages to AI provider (Anthropic / OpenAI / Google)
     │
     ▼
AI classifies intent: "command" or "chat"
     │
     ├── command → 3 options, user picks, execute
     │                └── if failure → self-correct → retry
     └── chat    → conversational answer displayed
     │
     ▼
Optional outputs (if enabled): funfact, linus quote, roast, ascii art
     │
     ▼
Log to memory + conversation buffer
```

---

## Platform Implementations

| Component | Bash/Zsh (Linux, macOS) | PowerShell (Windows) |
|-----------|------------------------|---------------------|
| Main script | `ai-shell.sh` | `ai-shell.ps1` |
| Installer | `install.sh` | `install.ps1` |
| HTTP client | `curl` | `Invoke-RestMethod` |
| JSON parser | `jq` | `ConvertFrom-Json` |
| System info | `uname`, `/proc/*`, `sysctl` | `Get-CimInstance` |
| Install location | `~/.ai-shell.sh` (sourced from `.bashrc`/`.zshrc`) | `~/.ai-shelly/ai-shell.ps1` (dot-sourced from PS profile) |
| Dependencies | `curl`, `jq` | None (built-in cmdlets) |

Both share the same config format (`config.json`) and file structure.

---

## Components

### 1. Config System

**Location:** `~/.config/ai-shell/config.json`

```json
{
    "provider": "openai",
    "model": "gpt-5-nano",
    "features": {
        "funfact": true,
        "linus_quotes": true,
        "ascii_art": false,
        "roast": false,
        "self_improve": true
    },
    "conversation": {
        "buffer_size": 3,
        "timeout_seconds": 1800
    }
}
```

**Features can be toggled at runtime:**
```
ai config                           # view all settings
ai config set features.roast true   # enable roast mode
ai config set provider openai       # switch provider
```

When a feature is disabled, the system prompt doesn't even ask the AI for that field — saving tokens.

### 2. Multi-Provider API Layer

Supports three providers with a unified interface:

| Provider | API Endpoint | Key Format | Default Model |
|----------|-------------|-----------|---------------|
| OpenAI | `api.openai.com/v1/chat/completions` | `sk-...` | `gpt-5-nano` |
| Google | `generativelanguage.googleapis.com/v1beta` | `AI...` | `gemini-3-flash` |
| Anthropic | `api.anthropic.com/v1/messages` | `sk-ant-...` | `claude-haiku-4-5-20251001` |

Provider is auto-detected from API key format during installation. Users can store per-provider keys:
- `~/.config/ai-shell/api-key` — default key
- `~/.config/ai-shell/api-key-anthropic` — provider-specific (takes precedence)

**Hot-swap at runtime:**
```
ai model openai                              # switch provider + default model
ai model anthropic claude-sonnet-4-20250514  # specific model
```

### 3. Intent Detection

The system prompt instructs the AI to classify each query:

- **Mode `"command"`** — user wants to perform a system action → return 3 executable options
- **Mode `"chat"`** — user wants an answer/explanation → return a conversational response

**Heuristics in the prompt:**
- Questions starting with "what is", "how does", "explain", "why" → chat
- Follow-up to previous conversation → chat (using conversation buffer context)
- Action verbs ("install", "delete", "find", "show") → command
- Piped input → command (analyze and respond to piped data)

### 4. Conversation Buffer

**Location:** `~/.cache/ai-shell/conversation.json`

Stores the last N exchanges (default: 3 pairs = 6 messages) as a JSON array:

```json
[
    {"role": "user", "content": "what is a symlink?", "ts": 1706000000},
    {"role": "assistant", "content": "{...}", "ts": 1706000001},
    {"role": "user", "content": "how do I create one?", "ts": 1706000010},
    {"role": "assistant", "content": "{...}", "ts": 1706000011}
]
```

- Messages are sent as multi-turn context in the API call
- Buffer auto-expires after 30 minutes of inactivity
- Cleared on `ai forget`
- Buffer size and timeout configurable in `config.json`

### 5. Memory System (Chunk & Bundle)

**Location:** `~/.cache/ai-shell/memory/chunks.jsonl`

Every interaction is logged as a JSONL line with: timestamp, working directory, query, command, explanation, and truncated output.

When building context for a new query, the **memory bundle** includes:
- **Recent history** — last 5 interactions
- **Keyword search** — top 3 relevant past interactions matching the current query

This gives the AI awareness of what the user has been working on.

### 6. System Context Collector

**Location:** `~/.cache/ai-shell/system-context.txt` (regenerated daily)

Collects platform-specific system information:

| Info | Linux/macOS | Windows PowerShell |
|------|-----------|-------------------|
| OS | `uname -srm`, `/etc/os-release` | `Get-CimInstance Win32_OperatingSystem` |
| CPU | `/proc/cpuinfo`, `sysctl` | `Get-CimInstance Win32_Processor` |
| RAM | `free -h`, `sysctl hw.memsize` | `Get-CimInstance Win32_ComputerSystem` |
| GPU | `lspci`, `system_profiler` | `Get-CimInstance Win32_VideoController` |
| Package mgr | `apt`, `dnf`, `pacman`, `brew`, ... | `winget`, `choco`, `scoop` |
| Shell | `$SHELL`, `$BASH_VERSION` | `$PSVersionTable` |

### 7. Self-Correction

When a command fails (non-zero exit, "command not found", "permission denied", etc.):
1. Failure is detected and classified
2. A retry prompt is sent to the AI with the error context
3. AI returns a corrected command
4. User is prompted to run the correction

### 8. Self-Improvement (opt-in)

Reads its own source code (first 3000 chars) + recent usage patterns, and asks the AI to suggest one practical improvement. Runs asynchronously after each interaction.

---

## Installer Design

Both installers follow the same flow:

```
1. Detect environment (OS, shell, package manager)
2. Check & install dependencies (platform-specific)
3. Copy script to install location
4. Hook into shell profile (bashrc/zshrc/PS profile)
5. Prompt for API key (auto-detect provider from key prefix)
6. Interactive feature toggle menu
7. Generate config.json
```

The installer is designed to be re-runnable — it skips steps that are already done (API key exists, source line already in profile, etc.).

---

## Response Format

The AI responds with structured JSON:

**Command mode:**
```json
{
    "mode": "command",
    "options": [
        {"command": "du -sh * | sort -rh | head -10", "label": "Quick disk usage"},
        {"command": "ncdu .", "label": "Interactive browser"},
        {"command": "df -h", "label": "Filesystem overview"}
    ],
    "explanation": "Shows disk usage sorted by size, largest first.",
    "funfact": "The du command dates back to Version 1 Unix in 1971.",
    "linus": "Talk is cheap. Show me the code."
}
```

**Chat mode:**
```json
{
    "mode": "chat",
    "answer": "A symlink (symbolic link) is a special file that points to another file or directory..."
}
```

---

## Cost Estimate

Using the lowest-cost model per provider:

| Provider | Model | Input Cost | Output Cost | ~Cost/Query |
|----------|-------|-----------|------------|------------|
| OpenAI | GPT-5-nano | $0.05/1M | $0.005/1M | ~$0.00003 |
| Google | Gemini 3 Flash | $0.50/1M | $3.00/1M | ~$0.0009 |
| Anthropic | Haiku 4.5 | $1.00/1M | $5.00/1M | ~$0.002 |

Typical query: ~500 tokens in, ~200 tokens out.
1,000 queries/month ≈ **$0.03–$2.00/month** depending on provider.

---

## Security

- API keys stored with restricted permissions (`chmod 600` on Linux/macOS)
- Commands always shown to user before execution — explicit confirmation required
- `eval` / `Invoke-Expression` is the main risk — mitigated by user confirmation
- Only system metadata and user queries are sent to the API — never file contents
- Conversation buffer stores AI responses locally, never sent to third parties

---

## File Structure

```
AI_Shelly/                          # Repository
├── ai-shell.sh                     # Bash/Zsh version
├── ai-shell.ps1                    # PowerShell version
├── install.sh                      # Bash installer
├── install.ps1                     # PowerShell installer
├── README.md                       # User-facing documentation
└── docs/
    ├── architecture.md             # This file — technical design
    └── backlog.md                  # Feature backlog & status tracking

~/.config/ai-shell/                 # User config (created by installer)
├── config.json                     # Features, provider, model
├── api-key                         # Default API key
└── api-key-<provider>              # Provider-specific keys (optional)

~/.cache/ai-shell/                  # Runtime data
├── system-context.txt              # Cached system info (daily)
├── conversation.json               # Active conversation buffer
└── memory/
    └── chunks.jsonl                # Interaction history

~/.ai-shell.sh                      # Installed bash script (Linux/macOS)
~/.ai-shelly/ai-shell.ps1           # Installed PS script (Windows)
```
