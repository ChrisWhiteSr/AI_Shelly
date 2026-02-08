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

## Low Severity — Open

### 4. `ask` function strips quotes too aggressively
**File:** `ai-shell.sh` line 576

`tr -d "'\`"` removes all single quotes and backticks from input, which could break intended command patterns like `find . -name '*.txt'`. Should only strip characters that would break JSON encoding, not valid shell syntax.

### 5. Retry logic shows empty command on malformed response
**File:** `ai-shell.sh` ~line 520

If the retry API response is malformed, the user gets a "Run corrected command?" prompt with nothing to run. Should check for empty `retry_cmd` before prompting.

### 6. Memory search is O(n*m)
**File:** `ai-shell.sh` ~lines 113-135

Iterates every keyword against every memory line. Will get slow with large history files. Could use `grep -E` with combined patterns for better performance.
