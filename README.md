# AI Shelly

A natural language shell assistant powered by AI. Ask for what you want in plain English, get back executable commands with explanations — or just have a conversation.

## Features

- **Natural language to commands** — Describe what you want, get 3 options to choose from
- **Smart intent detection** — Knows when you want a command vs. a conversational answer
- **Conversation memory** — Maintains context across exchanges for natural follow-ups
- **Multi-provider** — Works with Anthropic, OpenAI, and Google Gemini
- **Model hot-swap** — Switch providers/models on the fly with `ai model`
- **Configurable outputs** — Toggle fun facts, quotes, ASCII art, roast mode
- **Pipe mode** — Pipe command output for AI analysis: `dmesg | ai what errors are here`
- **Memory system** — Remembers past interactions for context-aware suggestions
- **Self-correction** — Detects command failures and auto-suggests fixes
- **Self-improvement** — Analyzes its own usage patterns and suggests enhancements
- **Cross-platform** — Native on Linux, macOS, and Windows PowerShell

## Quick Start

### Linux / macOS

```bash
git clone https://github.com/ChrisWhiteSr/AI_Shelly.git
cd AI_Shelly
chmod +x install.sh
./install.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/ChrisWhiteSr/AI_Shelly.git
cd AI_Shelly
.\install.ps1
```

Each platform gets its **native** version:
- **Linux/macOS** → bash functions via `ai-shell.sh`
- **PowerShell** → native PS functions via `ai-shell.ps1` (no WSL, no bash, no jq required)

The installer will:
1. Detect your OS, shell, and package manager
2. Install dependencies if needed (`curl`/`jq` on Linux/macOS — nothing extra on PowerShell)
3. Prompt for your API key (auto-detects provider from key format)
4. Let you choose which features to enable/disable
5. Generate `config.json` and hook into your shell profile

## Requirements

**Linux / macOS:** Bash 4+ (or Zsh), `curl`, `jq`
**Windows:** PowerShell 5.1+ (no additional dependencies)
**All platforms:** An API key from [Anthropic](https://console.anthropic.com/), [OpenAI](https://platform.openai.com/), or [Google](https://aistudio.google.com/)

## Usage

Works identically on **bash/zsh** and **PowerShell** — the AI generates platform-appropriate commands automatically.

```bash
# Ask in natural language — get commands
ai show me disk usage by folder

# Just ask a question — get a conversational answer
ai what is a symlink and when would I use one

# Follow up naturally (context is maintained)
ai how do I create one

# Interactive mode (handles special characters)
ask

# Pipe mode — analyze command output (bash/zsh)
journalctl -b | ai any errors?
ps aux | ai what is using the most memory

# Search past interactions
ai recall docker commands

# View/edit configuration
ai config
ai config set features.roast true

# Switch AI providers
ai model openai
ai model anthropic claude-sonnet-4-20250514
ai model google

# View history
ai history

# Wipe memory + conversation
ai forget
```

### PowerShell Examples

On PowerShell, AI Shelly returns **native PowerShell commands** (not bash):

```
PS> ai show me disk usage by folder
→ Shows disk usage for subdirectories in the current folder.

  [1] Get child item sizes
      $ Get-ChildItem -Directory | ForEach-Object { ... }
  [2] Use Windows utility
      $ Get-PSDrive C | Select-Object Used, Free
  [3] TreeSize approach
      $ Get-ChildItem -Recurse | Measure-Object -Property Length -Sum

PS> ai what is a symlink
→ A symbolic link is a file that points to another file or directory...
```

## How It Works

1. You type `ai <request>` in plain English
2. The AI detects your **intent** — command or conversation
3. **Command mode:** Returns 3 options, you pick one, it runs
4. **Chat mode:** Returns a natural language answer
5. Context from the last 3 exchanges is maintained for follow-ups
6. If a command fails, it auto-retries with a corrected version

### Intent Detection

AI Shelly is smart about knowing what you want:

| You type | Mode | What happens |
|----------|------|-------------|
| `ai delete all .tmp files` | Command | 3 command options to choose from |
| `ai what does chmod do` | Chat | Conversational explanation |
| `ai how do I create one` (after previous Q) | Chat | Context-aware follow-up |
| `dmesg \| ai any errors` | Command | Analyzes piped input |

### Memory System

Interactions are stored as JSONL chunks in `~/.cache/ai-shell/memory/`. The memory bundle includes:
- Recent command history (last 5)
- Keyword-matched relevant past interactions

### Conversation Buffer

The last 3 message exchanges are kept in `~/.cache/ai-shell/conversation.json` and sent as multi-turn context. Conversations auto-expire after 30 minutes of inactivity.

## Configuration

### Config File (`~/.config/ai-shell/config.json`)

```json
{
  "provider": "openai",
  "model": "gpt-5-nano",
  "features": {
    "funfact": true,
    "linus_quotes": true,
    "ascii_art": true,
    "roast": false,
    "self_improve": true
  },
  "conversation": {
    "buffer_size": 3,
    "timeout_seconds": 1800
  }
}
```

### Feature Toggles

| Feature | Config Key | Description |
|---------|-----------|-------------|
| Fun Facts | `features.funfact` | One-liner about the commands used |
| Linus Quotes | `features.linus_quotes` | Relevant Linus Torvalds quotes |
| ASCII Art | `features.ascii_art` | Random ASCII art footer |
| Roast Mode | `features.roast` | Brutal commentary (also via `AI_ROAST=1`) |
| Self-Improve | `features.self_improve` | Usage-based improvement suggestions |

Toggle at runtime:
```bash
ai config set features.roast true
ai config set features.ascii_art false
```

### File Locations

**Linux / macOS (`~` = `$HOME`):**

| File | Description |
|------|-------------|
| `~/.config/ai-shell/config.json` | Feature toggles, provider, model |
| `~/.config/ai-shell/api-key` | Default API key |
| `~/.config/ai-shell/api-key-<provider>` | Provider-specific key (optional) |
| `~/.cache/ai-shell/memory/chunks.jsonl` | Interaction log |
| `~/.cache/ai-shell/conversation.json` | Active conversation buffer |
| `~/.cache/ai-shell/system-context.txt` | Cached system info (daily refresh) |
| `~/.ai-shell.sh` | Installed script (sourced from shell RC) |

**Windows PowerShell (`~` = `$env:USERPROFILE`):**

| File | Description |
|------|-------------|
| `~\.config\ai-shell\config.json` | Feature toggles, provider, model |
| `~\.config\ai-shell\api-key` | Default API key |
| `~\.cache\ai-shell\memory\chunks.jsonl` | Interaction log |
| `~\.cache\ai-shell\conversation.json` | Active conversation buffer |
| `~\.ai-shelly\ai-shell.ps1` | Installed script (dot-sourced from PS profile) |

### Multi-Provider Support

| Provider | Key Format | Default Model | Notes |
|----------|-----------|---------------|-------|
| OpenAI | `sk-...` | `gpt-5-nano` | $0.05/1M in — cheapest |
| Google | `AI...` | `gemini-3-flash` | $0.50/1M in — latest gen |
| Anthropic | `sk-ant-...` | `claude-haiku-4-5` | $1.00/1M in — fast |

See all available models with `ai model`. Switch at runtime:
```
ai model openai              # shows models, switches to default
ai model openai gpt-5-mini   # switch to specific model
ai model google gemini-2.5-flash-lite  # ultra-cheap Google option
```

## Project Structure

```
AI_Shelly/
├── ai-shell.sh          # Bash/Zsh version (Linux, macOS)
├── ai-shell.ps1         # PowerShell version (Windows)
├── install.sh           # Smart installer for bash/zsh
├── install.ps1          # Smart installer for PowerShell
├── README.md
└── docs/
    ├── architecture.md  # Technical design & architecture
    └── backlog.md       # Feature backlog & status
```

## License

MIT
