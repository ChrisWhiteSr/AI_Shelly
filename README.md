# AI Shelly

A natural language shell assistant powered by Claude Haiku. Ask for what you want in plain English, get back executable commands with explanations.

## Features

- **Natural language to commands** - Describe what you want, get 3 options to choose from
- **Pipe mode** - Pipe command output for AI analysis: `dmesg | ai what errors are here`
- **Memory system** - Remembers past interactions for context-aware suggestions
- **Self-correction** - Detects command failures and auto-suggests fixes
- **Self-improvement** - Analyzes its own usage patterns and suggests enhancements
- **Roast mode** - Optional brutal commentary on your shell skills

## Quick Start

```bash
git clone https://github.com/ChrisWhiteSr/AI_Shelly.git
cd AI_Shelly
chmod +x install.sh
./install.sh
```

The installer will:
1. Copy the script to `~/.ai-shell.sh`
2. Add a `source` line to your `.bashrc` or `.zshrc`
3. Prompt for your Anthropic API key

## Requirements

- Bash 4+
- `curl` and `jq`
- An [Anthropic API key](https://console.anthropic.com/)

## Usage

```bash
# Ask in natural language
ai show me disk usage by folder

# Interactive mode (handles special characters)
ask

# Pipe mode - analyze command output
journalctl -b | ai any errors?
ps aux | ai what is using the most memory

# Search past interactions
ai recall docker commands

# View history
ai history

# Wipe memory
ai forget
```

## How It Works

1. You type `ai <request>` in plain English
2. Claude Haiku generates 3 command options with explanations
3. You pick one (or cancel)
4. The command runs, and the interaction is logged to memory
5. If the command fails, it auto-retries with a corrected version

### Memory System

Interactions are stored as JSONL chunks in `~/.cache/ai-shell/memory/`. The memory bundle includes:
- Recent command history (last 5)
- Keyword-matched relevant past interactions

This gives the AI context about what you've been working on.

## Configuration

| Setting | Location | Description |
|---------|----------|-------------|
| API Key | `~/.config/ai-shell/api-key` | Your Anthropic API key |
| Memory | `~/.cache/ai-shell/memory/chunks.jsonl` | Interaction log |
| System context | `~/.cache/ai-shell/system-context.txt` | Cached system info (refreshes daily) |

### Roast Mode

```bash
export AI_ROAST=1
```

Enables unhinged commentary on why you needed AI help for that command.

## License

MIT
