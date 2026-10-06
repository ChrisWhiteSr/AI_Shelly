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
    $model = _ai_load_config "model" (_ai_default_model $provider)
    $effort = _ai_load_config "reasoning_effort" "none"
    Write-Host "  Provider:     $provider" -ForegroundColor Cyan
    Write-Host "  Model:        $model" -ForegroundColor Cyan
    Write-Host "  Reasoning:    $effort  ('ai -t' uses medium)" -ForegroundColor Cyan
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
    param([string]$Provider = (_ai_load_config "provider" "openai"))
    $providerKeyFile = "$script:AI_CONFIG_DIR\api-key-$Provider"
    $defaultKeyFile = "$script:AI_CONFIG_DIR\api-key"
    if (Test-Path $providerKeyFile) { return (Get-Content $providerKeyFile -Raw).Trim() }
    if (Test-Path $defaultKeyFile) {
        # The shared api-key file only counts for the provider its prefix belongs to
        $key = (Get-Content $defaultKeyFile -Raw).Trim()
        $owner = if ($key.StartsWith("sk-ant-")) { "anthropic" } elseif ($key.StartsWith("sk-")) { "openai" } elseif ($key.StartsWith("AI")) { "google" } else { $Provider }
        if ($owner -eq $Provider) { return $key }
    }
    $envKey = switch ($Provider) {
        "anthropic" { $env:ANTHROPIC_API_KEY }
        "google" { if ($env:GEMINI_API_KEY) { $env:GEMINI_API_KEY } else { $env:GOOGLE_API_KEY } }
        default { $env:OPENAI_API_KEY }
    }
    if ($envKey) { return $envKey }
    return $null
}

function _ai_default_model {
    param([string]$Provider)
    switch ($Provider) {
        "anthropic" { return "claude-sonnet-5-5" }
        "google" { return "gemini-flash-latest" }
        default { return "gpt-6-sol" }
    }
}

# POST JSON; returns @{ Resp = <object or $null>; Err = <message or $null> }
function _ai_post {
    param([string]$Uri, [hashtable]$Headers, $Body)
    try {
        $json = $Body | ConvertTo-Json -Depth 8
        $resp = Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json" `
            -Headers $Headers -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 90
        return @{ Resp = $resp; Err = $null }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $msg = $_.ErrorDetails.Message }
        }
        return @{ Resp = $null; Err = $msg }
    }
}

# Effort levels used here: none (default, fastest), low (fixes), medium (ai -t)
function _ai_openai_effort {
    param([string]$Model, [string]$Effort)
    if ($Model -match '^(gpt-4|gpt-3\.5)' -or $Model -match 'chat-latest') { return $null }
    if ($Model -match '^gpt-5(-20|-mini|-nano|-codex|$)') { if ($Effort -eq "none") { return "minimal" } else { return $Effort } }
    if ($Model -match '^(o\d|gpt-6-astra|gpt-6\.1)' -or $Model -match '-pro') { if ($Effort -eq "none") { return "low" } else { return $Effort } }
    return $Effort
}

function _ai_call_api {
    param([string]$ApiKey, [string]$SystemPrompt, [array]$Messages, [string]$Effort = "none", [int]$MaxTokens = 8192)
    $provider = _ai_load_config "provider" "openai"
    $model = _ai_load_config "model" (_ai_default_model $provider)
    $msgs = @($Messages | ForEach-Object { @{ role = $_.role; content = $_.content } })

    switch ($provider) {
        "anthropic" {
            $extra = @{}
            if ($model -match '^claude-(3|haiku-4)' -or $model -match '^claude-.*-4-(5|1|0)' -or $model -match '^claude-.*-4-20') { }
            elseif ($model -like "claude-sonnet-5-5*") {
                if ($Effort -eq "none") { $extra = @{ thinking = @{ type = "between_tools" }; output_config = @{ effort = "low" } } }
                else { $extra = @{ output_config = @{ effort = $Effort } } }
            }
            else {
                $e = if ($Effort -eq "none") { "low" } else { $Effort }
                $extra = @{ output_config = @{ effort = $e } }
            }
            for ($attempt = 0; $attempt -lt 2; $attempt++) {
                $body = @{ model = $model; max_tokens = $MaxTokens; system = $SystemPrompt; messages = $msgs } + $extra
                $r = _ai_post "https://api.anthropic.com/v1/messages" @{ "x-api-key" = $ApiKey; "anthropic-version" = "2023-06-01" } $body
                if ($r.Err -and $extra.Count -gt 0 -and $r.Err -match 'thinking|effort|output_config') { $extra = @{}; continue }
                break
            }
            if ($r.Err) { Write-Host "API Error: $($r.Err)" -ForegroundColor Red; return $null }
            if ($r.Resp.stop_reason -eq "refusal") { Write-Host "The model declined this request." -ForegroundColor Red; return $null }
            # Thinking-capable models can return thinking blocks before the text
            return (@($r.Resp.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "")
        }
        "google" {
            $contents = @($msgs | ForEach-Object {
                    $role = if ($_.role -eq "assistant") { "model" } else { $_.role }
                    @{ role = $role; parts = @(@{ text = $_.content }) }
                })
            $thinking = $null
            if ($model -like "gemini-2.5-flash*") {
                $thinking = @{ thinkingBudget = $(switch ($Effort) { "none" { 0 } "low" { 1024 } default { 4096 } }) }
            }
            elseif ($model -notmatch '^gemini-[12]') {
                $thinking = @{ thinkingLevel = $(if ($Effort -eq "none") { "minimal" } else { $Effort }) }
            }
            for ($attempt = 0; $attempt -lt 2; $attempt++) {
                $gen = @{ maxOutputTokens = $MaxTokens; responseMimeType = "application/json" }
                if ($thinking) { $gen.thinkingConfig = $thinking }
                $body = @{ contents = $contents; systemInstruction = @{ parts = @(@{ text = $SystemPrompt }) }; generationConfig = $gen }
                $r = _ai_post "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" @{ "x-goog-api-key" = $ApiKey } $body
                if ($r.Err -and $thinking -and $r.Err -match 'hinking') { $thinking = $null; continue }
                break
            }
            if ($r.Err) { Write-Host "API Error: $($r.Err)" -ForegroundColor Red; return $null }
            return (@($r.Resp.candidates[0].content.parts | Where-Object { -not $_.thought } | ForEach-Object { $_.text }) -join "")
        }
        default {
            $effortVal = _ai_openai_effort $model $Effort
            $allMsgs = @(@{ role = "system"; content = $SystemPrompt }) + $msgs
            for ($attempt = 0; $attempt -lt 2; $attempt++) {
                $body = @{
                    model                 = $model
                    max_completion_tokens = $MaxTokens
                    messages              = $allMsgs
                    response_format       = @{ type = "json_object" }
                }
                if ($effortVal) { $body.reasoning_effort = $effortVal }
                $r = _ai_post "https://api.openai.com/v1/chat/completions" @{ "Authorization" = "Bearer $ApiKey" } $body
                # Self-heal when the model rejects the effort level: use the lowest one it supports
                if ($r.Err -and $r.Err -match 'reasoning_effort') {
                    $effortVal = if ($r.Err -match "Supported values are: '([a-z]+)'") { $Matches[1] } else { $null }
                    continue
                }
                break
            }
            if ($r.Err) { Write-Host "API Error: $($r.Err)" -ForegroundColor Red; return $null }
            return $r.Resp.choices[0].message.content
        }
    }
}

# Pull a JSON object out of model text (handles fences and chatter)
function _ai_parse_json {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch {}
    $start = $Text.IndexOf('{'); $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    try { return ($Text.Substring($start, $end - $start + 1) | ConvertFrom-Json) } catch { return $null }
}

function _ai_list_models {
    param([string]$Provider, [string]$ApiKey)
    try {
        switch ($Provider) {
            "anthropic" {
                (Invoke-RestMethod "https://api.anthropic.com/v1/models?limit=100" -Headers @{ "x-api-key" = $ApiKey; "anthropic-version" = "2023-06-01" }).data.id
            }
            "google" {
                (Invoke-RestMethod "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200" -Headers @{ "x-goog-api-key" = $ApiKey }).models |
                Where-Object { $_.supportedGenerationMethods -contains "generateContent" -and $_.name -match '^models/gemini' -and $_.name -notmatch 'image|tts|audio|embedding|live' } |
                ForEach-Object { $_.name -replace '^models/', '' } | Sort-Object
            }
            default {
                (Invoke-RestMethod "https://api.openai.com/v1/models" -Headers @{ "Authorization" = "Bearer $ApiKey" }).data.id |
                Where-Object { $_ -match '^(gpt-[4-9]|o\d)' -and $_ -notmatch 'audio|realtime|tts|transcribe|image|search|instruct|codex|live|-\d{4}-\d{2}-\d{2}$' } | Sort-Object
            }
        }
    }
    catch { Write-Host "Could not list models: $($_.Exception.Message)" -ForegroundColor Red }
}

# Local backstop in case the model under-reports risk
function _ai_looks_destructive {
    param([string]$Cmd)
    return ($Cmd -match '(Remove-Item|\brm\b|\bdel\b|\brd\b|rmdir).*-(Recurse|Force|r\b|rf\b)|Format-Volume|Clear-Disk|Initialize-Disk|Remove-Partition|\bformat\s+[a-z]:|diskpart|Stop-Computer|Restart-Computer|git\s+(reset\s+--hard|clean\s+-[a-z]*f|push\s.*--force)')
}

# Price ($ per 1M tokens in/out) and a hint, for models we know about (checked 2026-10)
function _ai_model_note {
    param([string]$Model)
    $notes = @{
        "gpt-6.1-sol"       = @('$2/$10', 'always reasons: smartest Sol, ~3x slower')
        "gpt-6-sol"         = @('$2/$10', 'smart + fast (recommended)')
        "gpt-6-luna"        = @('$0.10/$0.50', 'fast, ~20x cheaper')
        "gpt-6-astra"       = @('$10/$50', 'flagship, always reasons (slow)')
        "gpt-5.6-sol"       = @('$5/$30', '')
        "gpt-5.6-terra"     = @('$2/$12', '')
        "gpt-5.6-luna"      = @('$0.20/$1.20', '')
        "gpt-5.4-mini"      = @('$0.75/$4.50', 'fastest, older')
        "claude-sonnet-5-5" = @('$2/$10', 'smart, thinking off (recommended)')
        "claude-opus-5-5"   = @('$4/$20', 'always thinks (slower)')
        "claude-fable-5-1"  = @('$10/$50', 'most capable, always thinks (slow)')
        "claude-fable-5"    = @('$10/$50', 'most capable, always thinks (slow)')
        "claude-opus-5"     = @('$5/$25', '')
        "claude-sonnet-5"   = @('$2/$10', '')
        "claude-haiku-4-5"  = @('$1/$5', 'fastest Claude')
    }
    if ($notes.ContainsKey($Model)) { return $notes[$Model] }
    return @('', '')
}

# Newest chat models for a provider, newest first. Cached for a day.
function _ai_recent_models {
    param([string]$Provider, [int]$N = 6, [switch]$Refresh)
    $cache = "$script:AI_CACHE_DIR\models-$Provider.txt"
    $stale = -not (Test-Path $cache) -or ((Get-Item $cache).LastWriteTime -lt (Get-Date).AddDays(-1))
    if ($Refresh -or $stale) {
        $key = _ai_get_api_key $Provider
        if (-not $key) { return @() }
        try {
            $list = switch ($Provider) {
                "anthropic" {
                    (Invoke-RestMethod "https://api.anthropic.com/v1/models?limit=100" -Headers @{ "x-api-key" = $key; "anthropic-version" = "2023-06-01" }).data |
                    Sort-Object created_at -Descending | ForEach-Object { $_.id }
                }
                "openai" {
                    (Invoke-RestMethod "https://api.openai.com/v1/models" -Headers @{ "Authorization" = "Bearer $key" }).data |
                    Sort-Object created -Descending | ForEach-Object { $_.id } |
                    Where-Object { $_ -match '^(gpt-[4-9]|o\d)' -and $_ -notmatch 'pro|codex|audio|realtime|tts|transcribe|image|search|instruct|live|chat-latest|-\d{4}-\d{2}-\d{2}$' }
                }
                default { _ai_list_models $Provider $key | Sort-Object -Descending }
            }
        }
        catch { return @() }
        if (-not $list) { return @() }
        if (-not (Test-Path $script:AI_CACHE_DIR)) { New-Item -ItemType Directory -Path $script:AI_CACHE_DIR -Force | Out-Null }
        $list | Set-Content $cache
    }
    return @(Get-Content $cache | Select-Object -First $N)
}

# Interactive model picker across providers (Alt+M, or `ai model` with no arguments)
function _ai_pick_model {
    param([switch]$Refresh)
    $curP = _ai_load_config "provider" "openai"
    $curM = _ai_load_config "model" (_ai_default_model $curP)
    $entries = @()
    Write-Host ""
    Write-Host "Switch model  (current: $curP/$curM)" -ForegroundColor White
    foreach ($p in @("openai", "anthropic", "google")) {
        if (-not (_ai_get_api_key $p)) {
            if ($p -ne "google") { Write-Host "`n  ${p}: no key (save one to $script:AI_CONFIG_DIR\api-key-$p)" -ForegroundColor DarkGray }
            continue
        }
        $list = @(_ai_recent_models $p 6 -Refresh:$Refresh)
        if ($p -eq $curP -and $list -notcontains $curM) { $list += $curM }
        if ($list.Count -eq 0) { Write-Host "`n  ${p}: could not fetch models" -ForegroundColor Red; continue }
        Write-Host "`n  $p (newest first)" -ForegroundColor Cyan
        foreach ($m in $list) {
            $entries += [PSCustomObject]@{ Provider = $p; Model = $m }
            $mark = if ($p -eq $curP -and $m -eq $curM) { "●" } else { " " }
            $note = _ai_model_note $m
            Write-Host ("  {0} {1,2}  {2,-20} " -f $mark, $entries.Count, $m) -NoNewline
            Write-Host ("{0,-13} {1}" -f $note[0], $note[1]) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    $choice = Read-Host "Number, a model id, r to refresh, Enter to cancel"
    if (-not $choice) { Write-Host "Unchanged."; return }
    if ($choice -eq "r") { _ai_pick_model -Refresh; return }
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $entries.Count) {
        $newP = $entries[[int]$choice - 1].Provider; $newM = $entries[[int]$choice - 1].Model
    }
    else {
        $newM = $choice
        $newP = if ($newM -like "claude-*") { "anthropic" } elseif ($newM -like "gemini-*") { "google" } elseif ($newM -match '^(gpt-|o\d)') { "openai" } else { $null }
        if (-not $newP) { Write-Host "Not a number on the list or a known model id." -ForegroundColor Red; return }
    }
    _ai_set_config "provider" $newP
    _ai_set_config "model" $newM
    Write-Host "✓ Now using $newP/$newM" -ForegroundColor Green
}

# Last line of every answer: response time, model, how to switch
function _ai_footer {
    param([double]$Seconds, [string]$Provider, [string]$Model, [string]$Effort)
    $think = if ($Effort -ne "none") { " · reasoning: $Effort" } else { "" }
    Write-Host ""
    Write-Host ("⏱ {0:N1}s · {1}/{2}{3} · Alt+M to switch model" -f $Seconds, $Provider, $Model, $think) -ForegroundColor DarkGray
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
                $curProvider = _ai_load_config "provider" "openai"
                $curModel = _ai_load_config "model" (_ai_default_model $curProvider)

                # Curated picks (checked 2026-10). `ai models` lists everything your key can use.
                $showModels = {
                    param([string]$prov)
                    Write-Host ""
                    switch ($prov) {
                        "openai" {
                            Write-Host "  Recommended OpenAI models (`$ per 1M tokens in/out):" -ForegroundColor White
                            Write-Host "    gpt-6-sol           `$2.00/`$10.00  — smart + fast with reasoning off (default)" -ForegroundColor Green
                            Write-Host "    gpt-6-luna          `$0.10/`$0.50   — nearly as fast, ~20x cheaper" -ForegroundColor White
                            Write-Host "    gpt-5.4-mini        `$0.75/`$4.50   — fastest in testing, older generation" -ForegroundColor White
                            Write-Host "    gpt-6.1-sol         `$2.00/`$10.00  — always reasons: smarter, ~3x slower" -ForegroundColor White
                        }
                        "anthropic" {
                            Write-Host "  Recommended Anthropic models (`$ per 1M tokens in/out):" -ForegroundColor White
                            Write-Host "    claude-sonnet-5-5   `$2.00/`$10.00  — smart, thinking off for speed (default)" -ForegroundColor Green
                            Write-Host "    claude-haiku-4-5    `$1.00/`$5.00   — fastest, cheapest" -ForegroundColor White
                            Write-Host "    claude-opus-5-5     `$4.00/`$20.00  — most capable Opus, always thinks (slower)" -ForegroundColor White
                        }
                        "google" {
                            Write-Host "  Recommended Google models:" -ForegroundColor White
                            Write-Host "    gemini-flash-latest       — alias for Google's newest Flash (default)" -ForegroundColor Green
                            Write-Host "    gemini-flash-lite-latest  — alias for the newest Flash-Lite (cheapest)" -ForegroundColor White
                            Write-Host "    Run 'ai models google' for pinned version IDs." -ForegroundColor DarkGray
                        }
                    }
                    Write-Host ""
                }

                if ($Args.Count -lt 2 -and -not [Console]::IsOutputRedirected) {
                    _ai_pick_model
                    return
                }
                if ($Args.Count -lt 2) {
                    # No args — show current + recommended
                    Write-Host "Current: $curProvider / $curModel" -ForegroundColor Cyan
                    & $showModels $curProvider
                    Write-Host "  Usage:" -ForegroundColor DarkGray
                    Write-Host "    ai model <provider>          — switch provider (use default model)" -ForegroundColor DarkGray
                    Write-Host "    ai model <provider> <model>  — switch to specific model" -ForegroundColor DarkGray
                    Write-Host "    ai models [provider]         — list every model your key can use" -ForegroundColor DarkGray
                    Write-Host "    Providers: openai, anthropic, google" -ForegroundColor DarkGray
                    return
                }
                $newProvider = $Args[1]
                $newModel = if ($Args.Count -ge 3) { $Args[2] } else { $null }
                if (@("openai", "anthropic", "google") -notcontains $newProvider) {
                    Write-Host "Unknown provider: $newProvider (use: openai, anthropic, google)" -ForegroundColor Red
                    return
                }
                if (-not $newModel) {
                    $newModel = _ai_default_model $newProvider
                    & $showModels $newProvider
                    Write-Host "  Defaulting to: $newModel" -ForegroundColor DarkGray
                }
                _ai_set_config "provider" $newProvider
                _ai_set_config "model" $newModel
                Write-Host "✓ Switched to $newProvider / $newModel" -ForegroundColor Green
                if (-not (_ai_get_api_key $newProvider)) {
                    Write-Host "  No key found. Save one to $script:AI_CONFIG_DIR\api-key-$newProvider" -ForegroundColor Yellow
                }
                return
            }
            "models" {
                $p = if ($Args.Count -ge 2) { $Args[1] } else { _ai_load_config "provider" "openai" }
                $k = _ai_get_api_key $p
                if (-not $k) { Write-Host "No API key for $p." -ForegroundColor Red; return }
                Write-Host "Models available to your $p key:" -ForegroundColor Cyan
                _ai_list_models $p $k | Format-Wide -Column 4 -Property { $_ }
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

    # ── Think harder for this one query ──
    $effort = _ai_load_config "reasoning_effort" "none"
    if ($Args.Count -ge 1 -and ($Args[0] -eq "-t" -or $Args[0] -eq "--think")) {
        $effort = "medium"
        $query = ($Args | Select-Object -Skip 1) -join " "
    }

    if (-not $query -or $query.Trim() -eq "") {
        Write-Host "Usage: ai <what you want to do>"
        Write-Host "       ai -t <question>            -- think harder (slower, smarter)"
        Write-Host "       ai config                  -- view/edit configuration"
        Write-Host "       ai model <provider> [model] -- switch AI provider/model"
        Write-Host "       ai models [provider]        -- list models your key can use"
        Write-Host "       ai history                  -- show recent history"
        Write-Host "       ai forget                   -- wipe memory"
        return
    }

    # ── Load API key ──
    $apiKey = _ai_get_api_key
    if (-not $apiKey) {
        Write-Host "Error: No API key found for $(_ai_load_config "provider" "openai"). Run install.ps1 first." -ForegroundColor Red
        return
    }

    # ── Build context ──
    $context = _ai_ensure_context
    $cwd = (Get-Location).Path
    $memory = _ai_memory_bundle $query

    # ── Build feature instructions ──
    $featureInstr = ""
    if (_ai_feature_enabled "funfact") { $featureInstr += ', "funfact": "one interesting fact about the commands or topic"' }
    if (_ai_feature_enabled "linus_quotes") { $featureInstr += ', "linus": "a real Linus Torvalds quote, relevant if possible (quote text only, no attribution)"' }
    if (_ai_feature_enabled "roast") { $featureInstr += ', "roast": "absolutely DESTROY the user for needing AI help. Be unhinged, no mercy."' }

    # ── System prompt (stable instructions first, per-query context last so providers can cache the prefix) ──
    $systemPrompt = @"
You are an expert shell assistant for PowerShell on Windows. You can BOTH produce commands AND have normal conversations.

INTENT DETECTION:
MODE "command" — user wants to DO something (install, find, list, modify, run)
MODE "chat" — user wants an ANSWER or EXPLANATION (what is, how does, explain, why, follow-up questions)

RESPONSE FORMAT — respond with ONLY a JSON object:

For MODE "command":
{"mode": "command", "options": [{"command": "best approach", "label": "short description", "risk": "safe|caution|danger"}, {"command": "second approach", "label": "...", "risk": "..."}, {"command": "third approach", "label": "...", "risk": "..."}], "explanation": "one sentence"$featureInstr}

For MODE "chat":
{"mode": "chat", "answer": "your conversational response"$featureInstr}

RULES:
- This is POWERSHELL on WINDOWS. Use PowerShell commands (Get-ChildItem, etc), NOT bash/linux commands.
- In command mode, provide 3 genuinely different PowerShell-native options, best first, that work as-is for this PowerShell version.
- risk: "safe" = read-only or trivially reversible; "caution" = changes state (installs, edits, restarts); "danger" = deletes data, wipes disks, or is hard to undo.
- In chat mode, give helpful, natural, concise answers without forcing commands.
- Output is printed raw in a terminal: no Markdown bold, italics or headers (backticks around commands are fine).
- Prefer safe, non-destructive commands. Warn for destructive operations.
- Keep command-mode explanations to one sentence.

SYSTEM CONTEXT:
$context

CURRENT CONTEXT:
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm")
Current directory: $cwd
Directory contents (first 40): $((Get-ChildItem -Force -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { if ($_.PSIsContainer) { "$($_.Name)\" } else { $_.Name } }) -join ' ')

${memory}
"@

    Write-Host "Thinking..." -ForegroundColor DarkGray

    # ── Add to conversation buffer ──
    _ai_conversation_add "user" $query
    $messages = @(_ai_conversation_get_messages)
    if ($messages.Count -eq 0) { $messages = @([PSCustomObject]@{ role = "user"; content = $query }) }

    # ── API call ──
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $text = _ai_call_api -ApiKey $apiKey -SystemPrompt $systemPrompt -Messages $messages -Effort $effort
    $timer.Stop()
    $footer = { _ai_footer $timer.Elapsed.TotalSeconds (_ai_load_config "provider" "openai") (_ai_load_config "model" "") $effort }

    if (-not $text) {
        Write-Host "Error: No response from API" -ForegroundColor Red
        return
    }

    $parsed = _ai_parse_json $text
    if (-not $parsed) {
        Write-Host "Error: Invalid JSON response" -ForegroundColor Red
        Write-Host $text
        return
    }

    _ai_conversation_add "assistant" ($parsed | ConvertTo-Json -Depth 5 -Compress)

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
        $options = @($parsed.options | Where-Object { $_.command } | Select-Object -First 3)
        if (-not $explanation -and $options.Count -eq 0) {
            Write-Host "Error: Response had no explanation or commands." -ForegroundColor Red
            return
        }

        if ($explanation) { Write-Host "→ $explanation" -ForegroundColor Cyan }
        Write-Host ""

        if ($options.Count -gt 0) {
            $colors = @("Green", "Blue", "Magenta")
            $risks = @()
            for ($i = 0; $i -lt $options.Count; $i++) {
                $risk = if ($options[$i].risk) { "$($options[$i].risk)" } else { "safe" }
                if (_ai_looks_destructive $options[$i].command) { $risk = "danger" }
                $risks += $risk
                Write-Host "  [$($i+1)] $($options[$i].label)" -ForegroundColor $colors[$i] -NoNewline
                if ($risk -eq "danger") { Write-Host "  ⚠ destructive" -ForegroundColor Red }
                elseif ($risk -eq "caution") { Write-Host "  (changes system)" -ForegroundColor DarkYellow }
                else { Write-Host "" }
                Write-Host "      `$ $($options[$i].command)" -ForegroundColor Yellow
            }
            Write-Host ""

            $range = if ($options.Count -ge 2) { "1-$($options.Count)" } else { "1" }
            $choice = Read-Host "Pick [$range] or q to cancel"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $options.Count) {
                $idx = [int]$choice - 1
                $selectedCmd = $options[$idx].command
                if ($risks[$idx] -eq "danger") {
                    $confirm = Read-Host "This can destroy data. Type 'yes' to run it"
                    if ($confirm -ne "yes") { Write-Host "Cancelled."; & $footer; return }
                }
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
                & $footer
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

    & $footer
}

function ask {
    Write-Host "ai> " -ForegroundColor Cyan -NoNewline
    $rawQuery = Read-Host
    if (-not $rawQuery) { Write-Host "No query entered."; return }
    ai $rawQuery
}

# Alt+M opens the model picker
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Chord Alt+m -Description "AI Shelly: switch model" -ScriptBlock {
        Write-Host ""
        _ai_pick_model
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
}
