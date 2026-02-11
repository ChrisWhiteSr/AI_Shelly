# AI Shelly — Backlog

## Medium Severity — FIXED

### ~~1. JSON response parsing is fragile~~
**File:** `ai-shell.sh` ~line 453
**Status:** Fixed

Replaced the fragile `sed` one-liner with proper fence extraction: uses `sed -n` to extract content between fences, falls back to raw text if no fences found.

### ~~2. No validation of Claude's response structure~~
**File:** `ai-shell.sh` ~line 445-470
**Status:** Fixed

Added: JSON validity check (`jq empty`), required field validation (`explanation`), and graceful handling when `options` is null/empty/missing (shows explanation-only response instead of silent failure).

### ~~3. System context fails on non-Linux~~
**File:** `ai-shell.sh` ~lines 58-100
**Status:** Fixed

Added macOS/Darwin fallbacks for all system info: `sw_vers` for OS, `sysctl` for CPU/RAM, `system_profiler` for GPU, `brew` detection for package manager. Linux paths used only when available.

## High Priority — IMPLEMENTED

### ~~7. Configurable feature toggles (initialconfig)~~
**Files:** `install.sh`, `install.ps1`, `ai-shell.sh`, `ai-shell.ps1`
**Status:** Implemented

Users can now enable/disable features during installation or at runtime:
- `funfact` — Linux fun facts
- `linus_quotes` — Linus Torvalds quotes
- `ascii_art` — ASCII art footer
- `roast` — Roast mode
- `self_improve` — Self-improvement suggestions

Config stored as JSON at `~/.config/ai-shell/config.json`. Runtime management via `ai config` and `ai config set`. Works on both bash and PowerShell.

### ~~8. Smart cross-platform installer~~
**Files:** `install.sh`, `install.ps1`
**Status:** Implemented

Two native installers, each for its platform:
- **`install.sh`** — Linux, macOS (detects: distro, bash/zsh/fish, apt/dnf/pacman/zypper/brew/apk)
- **`install.ps1`** — Windows PowerShell (detects: PS version, winget/choco/scoop)

Both auto-detect API key provider from key prefix (Anthropic, OpenAI, Google) and present an interactive feature toggle menu. Each installs the platform-native script — no WSL or cross-shell redirection required.

### ~~9. Intent detection (command vs. chat mode)~~
**Files:** `ai-shell.sh`, `ai-shell.ps1`
**Status:** Implemented

AI now classifies each query as `"command"` or `"chat"` mode:
- **Command mode:** Returns 3 executable options (bash on Linux/macOS, PowerShell on Windows)
- **Chat mode:** Returns a conversational answer without forcing commands

Uses conversation context + explicit heuristics in the system prompt. Users can naturally ask follow-up questions or request explanations without getting unnecessary command suggestions.

### ~~10. Conversation buffer~~
**Files:** `ai-shell.sh`, `ai-shell.ps1`
**Status:** Implemented

Maintains the last N exchanges (default: 3) in `~/.cache/ai-shell/conversation.json`. Conversations auto-expire after 30 minutes of inactivity. Buffer size and timeout are configurable via `config.json`. Cleared on `ai forget`. Works on both bash and PowerShell.

### ~~11. Multi-provider model hot-swapping~~
**Files:** `ai-shell.sh`, `ai-shell.ps1`
**Status:** Implemented

Supports Anthropic, OpenAI, and Google Gemini APIs. Switch at runtime:
```
ai model openai              # switch to OpenAI (gpt-4o-mini)
ai model anthropic claude-sonnet-4-20250514  # specific model
ai model google              # switch to Gemini
```
Provider auto-detected from API key format during install. Per-provider API keys supported (`api-key-anthropic`, `api-key-openai`, etc.).

### ~~12. Native PowerShell port~~
**Files:** `ai-shell.ps1`, `install.ps1`
**Status:** Implemented

Full native PowerShell version of AI Shelly — no bash, no WSL, no jq, no curl required. Uses `Invoke-RestMethod`, `ConvertFrom-Json`, and `Get-CimInstance` for a zero-dependency Windows experience. System context detects Windows-specific info (CPU, RAM, GPU via CIM, package managers like winget/choco/scoop). AI generates PowerShell commands (e.g., `Get-ChildItem`) instead of bash commands.

## Low Severity — Open

### 4. `ask` function strips quotes too aggressively
**File:** `ai-shell.sh`

`tr -d "'\`"` removes all single quotes and backticks from input, which could break intended command patterns like `find . -name '*.txt'`. Should only strip characters that would break JSON encoding, not valid shell syntax.

### 5. Retry logic shows empty command on malformed response
**File:** `ai-shell.sh`

If the retry API response is malformed, the user gets a "Run corrected command?" prompt with nothing to run. Should check for empty `retry_cmd` before prompting.

### 6. Memory search is O(n*m)
**File:** `ai-shell.sh`

Iterates every keyword against every memory line. Will get slow with large history files. Could use `grep -E` with combined patterns for better performance.

## Future Enhancements — Planned

### 13. Streaming responses
Stream API responses for a faster-feeling UX. Requires chunked curl/Invoke-WebRequest parsing.

### 14. Cost tracking
Track token usage per call, show monthly spend with `ai cost`.

### 15. Tab completion
Bash/Zsh/PowerShell completions for subcommands and common prefixes.

### 16. Conversation mode (`ai -c`)
Dedicated multi-turn conversation REPL — stay in a chat loop without re-typing `ai` each time.

### 17. Auto-run mode (`ai -y`)
Skip confirmation for safe, non-destructive commands.

### 18. macOS-native enhancements
Detect and use macOS-specific tools (e.g., `open`, `pbcopy`, `defaults`, `launchctl`) in command suggestions.
