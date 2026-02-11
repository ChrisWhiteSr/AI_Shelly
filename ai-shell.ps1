# ai-shell.ps1 — Natural language shell assistant for PowerShell
# Native PowerShell port — no bash, no WSL, no jq required

$script:AI_CONFIG_DIR = "$env:USERPROFILE\.config\ai-shell"
$script:AI_CONFIG_FILE = "$script:AI_CONFIG_DIR\config.json"
$script:AI_CACHE_DIR = "$env:USERPROFILE\.cache\ai-shell"
$script:AI_MEMORY_DIR = "$script:AI_CACHE_DIR\memory"
$script:AI_MEMORY_INDEX = "$script:AI_MEMORY_DIR\chunks.jsonl"
$script:AI_CONVERSATION_FILE = "$script:AI_CACHE_DIR\conversation.json"

# ═══════════════════════════════════════
# CONFIG SYSTEM
# ═══════════════════════════════════════

function _ai_load_config {
    param([string]$Key, [string]$Default)
    if (Test-Path $script:AI_CONFIG_FILE) {
        try {
            $cfg = Get-Content $script:AI_CONFIG_FILE -Raw | ConvertFrom-Json
            $parts = $Key.TrimStart('.') -split '\.'
            $val = $cfg
            foreach ($p in $parts) { $val = $val.$p }
            if ($null -ne $val -and "$val" -ne "") { return "$val" }
        }
        catch {}
    }
    return $Default
}

function _ai_feature_enabled {
    param([string]$Feature)
    $val = _ai_load_config -Key "features.$Feature" -Default "True"
    return $val -eq "True"
}

function _ai_set_config {
    param([string]$Key, $Value)
    if (-not (Test-Path $script:AI_CONFIG_DIR)) { New-Item -ItemType Directory -Path $script:AI_CONFIG_DIR -Force | Out-Null }
    if (-not (Test-Path $script:AI_CONFIG_FILE)) { '{}' | Set-Content $script:AI_CONFIG_FILE }
    $cfg = Get-Content $script:AI_CONFIG_FILE -Raw | ConvertFrom-Json
    $parts = $Key.TrimStart('.') -split '\.'
    $obj = $cfg
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if ($null -eq $obj.($parts[$i])) {
            $obj | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $obj = $obj.($parts[$i])
    }
    $leaf = $parts[-1]
    if ($Value -is [bool] -or $Value -eq "true" -or $Value -eq "false") {
        $boolVal = if ($Value -eq "true" -or $Value -eq $true) { $true } else { $false }
        if ($null -eq $obj.$leaf) { $obj | Add-Member -NotePropertyName $leaf -NotePropertyValue $boolVal -Force }
        else { $obj.$leaf = $boolVal }
    }
    else {
        if ($null -eq $obj.$leaf) { $obj | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force }
        else { $obj.$leaf = $Value }
    }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $script:AI_CONFIG_FILE
}

function _ai_show_config {
    if (-not (Test-Path $script:AI_CONFIG_FILE)) {
        Write-Host "No config file found. Run install.ps1 first." -ForegroundColor Red
        return
    }
    Write-Host ""
    Write-Host "┌─ AI Shelly Configuration ─┐" -ForegroundColor White
    Write-Host ""
    $provider = _ai_load_config "provider" "openai"
    $model = _ai_load_config "model" "gpt-4o-mini"
    Write-Host "  Provider:     $provider" -ForegroundColor Cyan
    Write-Host "  Model:        $model" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Features:" -ForegroundColor White
    foreach ($feat in @("funfact", "linus_quotes", "ascii_art", "roast", "self_improve")) {
        $val = _ai_load_config "features.$feat" "True"
        $icon = if ($val -eq "True") { "✓" } else { "✗" }
        $color = if ($val -eq "True") { "Green" } else { "Red" }
        Write-Host "    $icon $($feat.PadRight(18)) ($val)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  Config: $script:AI_CONFIG_FILE" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════
# ASCII ART
# ═══════════════════════════════════════

function _ai_random_art {
    $arts = @(
        "   ┌─┐`n   ┴─┴`n   ಠ_ರೃ  quite."
        "   ( •_•)`n   ( •_•)>⌐■-■`n   (⌐■_■)  deal with it"
        "     .  *  .`n   *  🐧  *`n     .  *  .`n   kernel vibes"
        "   ┬─┬ ノ( ゜-゜ノ)`n   calm down"
        "   (╯°□°)╯︵ ┻━┻`n   FLIP THE TABLE"
        "   ᕦ(ò_óˇ)ᕤ`n   flexing on the kernel"
        "   🔥🔥🔥🔥🔥🔥🔥`n    this terminal is`n      ON FIRE`n   🔥🔥🔥🔥🔥🔥🔥"
        "   [sudo] password for root:`n   lol nice try"
    )
    $idx = Get-Random -Minimum 0 -Maximum $arts.Count
    return $arts[$idx]
}

# ═══════════════════════════════════════
# SYSTEM CONTEXT (Windows / PowerShell)
# ═══════════════════════════════════════

function _ai_generate_context {
    $ctx = @()
    $ctx += "System: Windows $([System.Environment]::OSVersion.Version) ($env:PROCESSOR_ARCHITECTURE)"

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $ctx += "OS: $($os.Caption) Build $($os.BuildNumber)"
    }
    catch { $ctx += "OS: Windows" }

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $ctx += "CPU: $($cpu.Name)"
    }
    catch {}

    try {
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        $ctx += "RAM: ${ram}GB"
    }
    catch {}

    try {
        $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
        if ($gpu.Name) { $ctx += "GPU: $($gpu.Name)" }
    }
    catch {}

    $ctx += "Shell: PowerShell $($PSVersionTable.PSVersion)"
    $ctx += "User: $env:USERNAME"

    # Detect package managers
    $pkgs = @()
    if (Get-Command choco -ErrorAction SilentlyContinue) { $pkgs += "chocolatey" }
    if (Get-Command scoop -ErrorAction SilentlyContinue) { $pkgs += "scoop" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { $pkgs += "winget" }
    if ($pkgs.Count -gt 0) { $ctx += "Package managers: $($pkgs -join ', ')" }

    return ($ctx -join "`n")
}

function _ai_ensure_context {
    $cacheFile = "$script:AI_CACHE_DIR\system-context.txt"
    if (-not (Test-Path $script:AI_CACHE_DIR)) { New-Item -ItemType Directory -Path $script:AI_CACHE_DIR -Force | Out-Null }
    $regen = $false
    if (-not (Test-Path $cacheFile)) { $regen = $true }
    else {
        $lastWrite = (Get-Item $cacheFile).LastWriteTime.Date
        if ($lastWrite -ne (Get-Date).Date) { $regen = $true }
    }
    if ($regen) { _ai_generate_context | Set-Content $cacheFile }
    return (Get-Content $cacheFile -Raw)
}

# ═══════════════════════════════════════
# MEMORY SYSTEM
# ═══════════════════════════════════════

function _ai_memory_log {
    param([string]$Query, [string]$Command, [string]$Explanation, [string]$Output)
    if (-not (Test-Path $script:AI_MEMORY_DIR)) { New-Item -ItemType Directory -Path $script:AI_MEMORY_DIR -Force | Out-Null }
    $entry = @{
        ts          = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        cwd         = (Get-Location).Path
        query       = $Query
        command     = $Command
        explanation = $Explanation
        output      = if ($Output.Length -gt 500) { $Output.Substring(0, 500) } else { $Output }
    } | ConvertTo-Json -Compress
    Add-Content -Path $script:AI_MEMORY_INDEX -Value $entry
}

function _ai_memory_recent {
    param([int]$N = 5)
    if (-not (Test-Path $script:AI_MEMORY_INDEX)) { return "" }
    $lines = Get-Content $script:AI_MEMORY_INDEX | Select-Object -Last $N
    $result = @()
    foreach ($line in $lines) {
        try {
            $obj = $line | ConvertFrom-Json
            $cmd = if ($obj.command) { $obj.command } else { "no command" }
            $result += "[$($obj.ts)] Q: $($obj.query) → $cmd | $($obj.explanation)"
        }
        catch {}
    }
    return ($result -join "`n")
}

function _ai_memory_bundle {
    param([string]$Query)
    $bundle = ""
    $recent = _ai_memory_recent 5
    if ($recent) { $bundle += "RECENT HISTORY (last 5 commands):`n$recent`n`n" }
    return $bundle
}

# ═══════════════════════════════════════
# CONVERSATION BUFFER
# ═══════════════════════════════════════

function _ai_conversation_init {
    if (-not (Test-Path $script:AI_CACHE_DIR)) { New-Item -ItemType Directory -Path $script:AI_CACHE_DIR -Force | Out-Null }
    if (-not (Test-Path $script:AI_CONVERSATION_FILE)) { '[]' | Set-Content $script:AI_CONVERSATION_FILE }
}

function _ai_conversation_expired {
    $timeout = [int](_ai_load_config "conversation.timeout_seconds" "1800")
    if (-not (Test-Path $script:AI_CONVERSATION_FILE)) { return $true }
    try {
        $conv = Get-Content $script:AI_CONVERSATION_FILE -Raw | ConvertFrom-Json
        if ($conv.Count -eq 0) { return $true }
        $lastTs = $conv[-1].ts
        $now = [int][double]::Parse((Get-Date -UFormat %s))
        return (($now - $lastTs) -gt $timeout)
    }
    catch { return $true }
}

function _ai_conversation_add {
    param([string]$Role, [string]$Content)
    _ai_conversation_init
    $bufSize = [int](_ai_load_config "conversation.buffer_size" "3")
    $maxEntries = $bufSize * 2
    $now = [int][double]::Parse((Get-Date -UFormat %s))

    if (_ai_conversation_expired) { '[]' | Set-Content $script:AI_CONVERSATION_FILE }

    $conv = @(Get-Content $script:AI_CONVERSATION_FILE -Raw | ConvertFrom-Json)
    $conv += [PSCustomObject]@{ role = $Role; content = $Content; ts = $now }
    if ($conv.Count -gt $maxEntries) { $conv = $conv[($conv.Count - $maxEntries)..($conv.Count - 1)] }
    ConvertTo-Json $conv -Depth 3 | Set-Content $script:AI_CONVERSATION_FILE
}

function _ai_conversation_get_messages {
    _ai_conversation_init
    if (_ai_conversation_expired) { return @() }
    try {
        $conv = @(Get-Content $script:AI_CONVERSATION_FILE -Raw | ConvertFrom-Json)
        return $conv | ForEach-Object { [PSCustomObject]@{ role = $_.role; content = $_.content } }
    }
    catch { return @() }
}

function _ai_conversation_clear {
    '[]' | Set-Content $script:AI_CONVERSATION_FILE -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════
# MULTI-PROVIDER API CALLS
# ═══════════════════════════════════════

function _ai_get_api_key {
    $provider = _ai_load_config "provider" "openai"
    $providerKeyFile = "$script:AI_CONFIG_DIR\api-key-$provider"
    $defaultKeyFile = "$script:AI_CONFIG_DIR\api-key"
    if (Test-Path $providerKeyFile) { return (Get-Content $providerKeyFile -Raw).Trim() }
    if (Test-Path $defaultKeyFile) { return (Get-Content $defaultKeyFile -Raw).Trim() }
    return $null
}

function _ai_call_api {
    param([string]$ApiKey, [string]$SystemPrompt, [array]$Messages, [int]$MaxTokens = 1024)
    $provider = _ai_load_config "provider" "openai"
    $model = _ai_load_config "model" "gpt-4o-mini"

    try {
        switch ($provider) {
            "anthropic" {
                $body = @{
                    model      = $model
                    max_tokens = $MaxTokens
                    system     = $SystemPrompt
                    messages   = @($Messages | ForEach-Object { @{ role = $_.role; content = $_.content } })
                } | ConvertTo-Json -Depth 5
                $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
                    -Method Post -ContentType "application/json" `
                    -Headers @{ "x-api-key" = $ApiKey; "anthropic-version" = "2023-06-01" } `
                    -Body $body -TimeoutSec 30
                return $resp.content[0].text
            }
            "openai" {
                $allMsgs = @(@{ role = "system"; content = $SystemPrompt })
                $allMsgs += @($Messages | ForEach-Object { @{ role = $_.role; content = $_.content } })
                $body = @{
                    model      = $model
                    max_tokens = $MaxTokens
                    messages   = $allMsgs
                } | ConvertTo-Json -Depth 5
                $resp = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
                    -Method Post -ContentType "application/json" `
                    -Headers @{ "Authorization" = "Bearer $ApiKey" } `
                    -Body $body -TimeoutSec 30
                return $resp.choices[0].message.content
            }
            "google" {
                $contents = @($Messages | ForEach-Object {
                        $r = if ($_.role -eq "assistant") { "model" } else { $_.role }
                        @{ role = $r; parts = @(@{ text = $_.content }) }
                    })
                $body = @{
                    contents          = $contents
                    systemInstruction = @{ parts = @(@{ text = $SystemPrompt }) }
                    generationConfig  = @{ maxOutputTokens = $MaxTokens }
                } | ConvertTo-Json -Depth 6
                $resp = Invoke-RestMethod -Uri "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${ApiKey}" `
                    -Method Post -ContentType "application/json" `
                    -Body $body -TimeoutSec 30
                return $resp.candidates[0].content.parts[0].text
            }
        }
    }
    catch {
        Write-Host "API Error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ═══════════════════════════════════════
# MAIN FUNCTION
# ═══════════════════════════════════════

function ai {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $query = $Args -join " "

    # ── Subcommands ──
    if ($Args.Count -ge 1) {
        switch ($Args[0]) {
            "config" {
                if ($Args.Count -ge 3 -and $Args[1] -eq "set") {
                    $key = $Args[2]; $val = $Args[3]
                    _ai_set_config $key $val
                    Write-Host "✓ Set $key = $val" -ForegroundColor Green
                }
                else { _ai_show_config }
                return
            }
            "model" {
                if ($Args.Count -lt 2) {
                    $p = _ai_load_config "provider" "openai"
                    $m = _ai_load_config "model" "gpt-4o-mini"
                    Write-Host "Current: $p / $m" -ForegroundColor Cyan
                    Write-Host "`nUsage: ai model <provider> [model-name]"
                    Write-Host "  Providers: anthropic, openai, google"
                    return
                }
                $newProvider = $Args[1]
                $newModel = if ($Args.Count -ge 3) { $Args[2] } else { $null }
                $defaults = @{ anthropic = "claude-haiku-4-5-20251001"; openai = "gpt-4o-mini"; google = "gemini-2.0-flash" }
                if (-not $defaults.ContainsKey($newProvider)) {
                    Write-Host "Unknown provider: $newProvider" -ForegroundColor Red; return
                }
                if (-not $newModel) { $newModel = $defaults[$newProvider] }
                _ai_set_config "provider" $newProvider
                _ai_set_config "model" $newModel
                Write-Host "✓ Switched to $newProvider / $newModel" -ForegroundColor Green
                return
            }
            "recall" {
                Write-Host "Memory search not yet implemented in PS version." -ForegroundColor Yellow
                return
            }
            "history" {
                if (-not (Test-Path $script:AI_MEMORY_INDEX)) { Write-Host "No history yet."; return }
                $count = (Get-Content $script:AI_MEMORY_INDEX).Count
                Write-Host "$count interactions logged" -ForegroundColor Cyan
                Write-Host ""
                Write-Host (_ai_memory_recent 20)
                return
            }
            "forget" {
                if (Test-Path $script:AI_MEMORY_INDEX) { Remove-Item $script:AI_MEMORY_INDEX; Write-Host "Memory wiped." }
                _ai_conversation_clear
                Write-Host "Conversation buffer cleared."
                return
            }
        }
    }

    if (-not $query -or $query.Trim() -eq "") {
        Write-Host "Usage: ai <what you want to do>"
        Write-Host "       ai config                  -- view/edit configuration"
        Write-Host "       ai model <provider>         -- switch AI provider"
        Write-Host "       ai history                  -- show recent history"
        Write-Host "       ai forget                   -- wipe memory"
        return
    }

    # ── Load API key ──
    $apiKey = _ai_get_api_key
    if (-not $apiKey) {
        Write-Host "Error: No API key found. Run install.ps1 first." -ForegroundColor Red
        return
    }

    # ── Build context ──
    $context = _ai_ensure_context
    $cwd = (Get-Location).Path
    $memory = _ai_memory_bundle $query

    # ── Build feature instructions ──
    $featureInstr = ""
    if (_ai_feature_enabled "funfact") { $featureInstr += ', "funfact": "one interesting fact about the commands or topic"' }
    if (_ai_feature_enabled "linus_quotes") { $featureInstr += ', "linus": "a real Linus Torvalds quote, relevant if possible"' }
    if (_ai_feature_enabled "roast") { $featureInstr += ', "roast": "absolutely DESTROY the user for needing AI help. Be unhinged, no mercy."' }

    # ── System prompt ──
    $systemPrompt = @"
You are a versatile shell assistant for PowerShell on Windows. You can BOTH execute commands AND have normal conversations.

INTENT DETECTION:
MODE "command" — user wants to DO something (install, find, list, modify, run)
MODE "chat" — user wants an ANSWER or EXPLANATION (what is, how does, explain, why, follow-up questions)

SYSTEM CONTEXT:
$context

CURRENT DIRECTORY: $cwd

${memory}RESPONSE FORMAT — respond with ONLY a JSON object (no markdown fences):

For MODE "command":
{"mode": "command", "options": [{"command": "first approach", "label": "short description"}, {"command": "second approach", "label": "short description"}, {"command": "third approach", "label": "short description"}], "explanation": "one sentence"$featureInstr}

For MODE "chat":
{"mode": "chat", "answer": "your conversational response"$featureInstr}

RULES:
- This is POWERSHELL on WINDOWS. Use PowerShell commands (Get-ChildItem, etc), NOT bash/linux commands.
- In command mode, provide exactly 3 PowerShell-native options.
- In chat mode, give helpful natural answers without forcing commands.
- Prefer safe, non-destructive commands. Warn for destructive operations.
- Keep command-mode explanations to one sentence.
"@

    Write-Host "Thinking..." -ForegroundColor DarkGray

    # ── Add to conversation buffer ──
    _ai_conversation_add "user" $query
    $messages = @(_ai_conversation_get_messages)
    if ($messages.Count -eq 0) { $messages = @([PSCustomObject]@{ role = "user"; content = $query }) }

    # ── API call ──
    $text = _ai_call_api -ApiKey $apiKey -SystemPrompt $systemPrompt -Messages $messages -MaxTokens 1024

    if (-not $text) {
        Write-Host "Error: No response from API" -ForegroundColor Red
        return
    }

    # Strip markdown fences
    if ($text -match '(?s)```(?:json)?\s*(.+?)```') { $text = $Matches[1].Trim() }

    try { $parsed = $text | ConvertFrom-Json } catch {
        Write-Host "Error: Invalid JSON response" -ForegroundColor Red
        Write-Host $text
        return
    }

    _ai_conversation_add "assistant" $text

    # Clear "Thinking..." — move cursor up
    Write-Host "`e[1A`e[2K" -NoNewline

    $mode = if ($parsed.mode) { $parsed.mode } else { "command" }

    # ══════════════════════════════════
    # CHAT MODE
    # ══════════════════════════════════
    if ($mode -eq "chat") {
        $answer = if ($parsed.answer) { $parsed.answer } else { $parsed.explanation }
        if ($answer) { Write-Host $answer -ForegroundColor Cyan }
        _ai_memory_log $query "" $answer ""
    }
    # ══════════════════════════════════
    # COMMAND MODE
    # ══════════════════════════════════
    else {
        $explanation = $parsed.explanation
        if (-not $explanation) {
            Write-Host "Error: Response missing explanation." -ForegroundColor Red
            return
        }

        Write-Host "→ $explanation" -ForegroundColor Cyan
        Write-Host ""

        $options = $parsed.options
        if ($options -and $options.Count -gt 0) {
            $colors = @("Green", "Blue", "Magenta")
            for ($i = 0; $i -lt [Math]::Min($options.Count, 3); $i++) {
                Write-Host "  [$($i+1)] $($options[$i].label)" -ForegroundColor $colors[$i]
                Write-Host "      `$ $($options[$i].command)" -ForegroundColor Yellow
            }
            Write-Host ""

            $choice = Read-Host "Pick [1/2/3] or q to cancel"
            if ($choice -match '^[123]$') {
                $idx = [int]$choice - 1
                $selectedCmd = $options[$idx].command
                Write-Host ""
                Write-Host "  `$ $selectedCmd" -ForegroundColor Yellow
                Write-Host ""

                try {
                    $output = Invoke-Expression $selectedCmd 2>&1 | Out-String
                    Write-Host $output
                    _ai_memory_log $query $selectedCmd $explanation $output
                }
                catch {
                    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
                    _ai_memory_log $query $selectedCmd $explanation "ERROR: $($_.Exception.Message)"
                }
            }
            else {
                Write-Host "Cancelled."
                return
            }
        }
        else {
            _ai_memory_log $query "" $explanation ""
        }
    }

    # ── Optional features ──
    if ($parsed.funfact -and (_ai_feature_enabled "funfact")) {
        Write-Host ""
        Write-Host "✦ $($parsed.funfact)" -ForegroundColor Green
    }
    if ($parsed.linus -and (_ai_feature_enabled "linus_quotes")) {
        Write-Host "🐧 `"$($parsed.linus)`" -- Linus Torvalds" -ForegroundColor Red
    }
    if ($parsed.roast -and (_ai_feature_enabled "roast")) {
        Write-Host "🔥 $($parsed.roast)" -ForegroundColor DarkGray
    }
    if (_ai_feature_enabled "ascii_art") {
        Write-Host ""
        Write-Host (_ai_random_art) -ForegroundColor DarkGray
    }
}

function ask {
    Write-Host "ai> " -ForegroundColor Cyan -NoNewline
    $rawQuery = Read-Host
    if (-not $rawQuery) { Write-Host "No query entered."; return }
    ai $rawQuery
}
