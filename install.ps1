# AI Shelly — PowerShell Installer
# Installs the native PowerShell version of AI Shelly

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceFile = Join-Path $ScriptDir "ai-shell.ps1"
$InstallDir = "$env:USERPROFILE\.ai-shelly"
$InstallFile = "$InstallDir\ai-shell.ps1"
$ConfigDir = "$env:USERPROFILE\.config\ai-shell"
$ConfigFile = "$ConfigDir\config.json"
$KeyFile = "$ConfigDir\api-key"

Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       AI Shelly — Installer          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ──────────────────────────────────────
# 1. DETECT ENVIRONMENT
# ──────────────────────────────────────
$osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
$psVer = $PSVersionTable.PSVersion
$shellType = "PowerShell"

# Detect if running in PS Core vs Windows PS
if ($PSVersionTable.PSEdition -eq "Core") { $shellType = "PowerShell Core" }

Write-Host "Detected environment:" -ForegroundColor Cyan
Write-Host "  OS:    $osCaption" -ForegroundColor Green
Write-Host "  Shell: $shellType $psVer" -ForegroundColor Green

# Detect package managers
$pkgManagers = @()
if (Get-Command winget -ErrorAction SilentlyContinue) { $pkgManagers += "winget" }
if (Get-Command choco -ErrorAction SilentlyContinue) { $pkgManagers += "chocolatey" }
if (Get-Command scoop -ErrorAction SilentlyContinue) { $pkgManagers += "scoop" }
if ($pkgManagers.Count -gt 0) { Write-Host "  Pkgs:  $($pkgManagers -join ', ')" -ForegroundColor Green }
Write-Host ""

# ──────────────────────────────────────
# 2. INSTALL SCRIPT
# ──────────────────────────────────────
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Copy-Item $SourceFile $InstallFile -Force
Write-Host "✓ Installed to $InstallFile" -ForegroundColor Green

# ──────────────────────────────────────
# 3. HOOK INTO POWERSHELL PROFILE
# ──────────────────────────────────────
$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir = Split-Path $profilePath -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }

$sourceLine = ". `"$InstallFile`""
$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent -or -not $profileContent.Contains("ai-shell.ps1")) {
    Add-Content $profilePath "`n# AI Shelly — natural language shell assistant"
    Add-Content $profilePath $sourceLine
    Write-Host "✓ Added to PowerShell profile: $profilePath" -ForegroundColor Green
}
else {
    Write-Host "  Profile already configured (skipped)" -ForegroundColor DarkGray
}

# ──────────────────────────────────────
# 4. API KEY SETUP
# ──────────────────────────────────────
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }

$provider = "openai"
$model = "gpt-5-nano"

if (Test-Path $KeyFile) {
    Write-Host "  API key already configured." -ForegroundColor DarkGray
    $existingKey = (Get-Content $KeyFile -Raw).Trim()
    if ($existingKey.StartsWith("sk-ant-")) { $provider = "anthropic" }
    elseif ($existingKey.StartsWith("sk-")) { $provider = "openai" }
    elseif ($existingKey.StartsWith("AI")) { $provider = "google" }
}
else {
    Write-Host ""
    Write-Host "API Key Setup" -ForegroundColor White
    Write-Host "  Supported providers:" -ForegroundColor DarkGray
    Write-Host "    Anthropic  → sk-ant-..." -ForegroundColor DarkGray
    Write-Host "    OpenAI     → sk-..." -ForegroundColor DarkGray
    Write-Host "    Google     → AI..." -ForegroundColor DarkGray
    Write-Host ""
    $apiKey = Read-Host "Paste your API key (or press Enter to skip)"
    if ($apiKey) {
        $apiKey | Set-Content $KeyFile -NoNewline
        if ($apiKey.StartsWith("sk-ant-")) { $provider = "anthropic" }
        elseif ($apiKey.StartsWith("sk-")) { $provider = "openai" }
        elseif ($apiKey.StartsWith("AI")) { $provider = "google" }
        Write-Host "✓ API key saved (detected provider: $provider)" -ForegroundColor Green
    }
    else {
        Write-Host "  Skipped. Add your key later:" -ForegroundColor Yellow
        Write-Host "    'your-key' | Set-Content $KeyFile" -ForegroundColor Yellow
    }
}

# ──────────────────────────────────────
# 4b. MODEL SELECTION
# ──────────────────────────────────────
Write-Host ""
Write-Host "Model Selection (provider: $provider)" -ForegroundColor White
Write-Host "  Choose your model. Switch anytime with: ai model" -ForegroundColor DarkGray
Write-Host ""

switch ($provider) {
    "openai" {
        Write-Host "  [1] gpt-5-nano          `$0.05/1M in   — ultra-cheap, fastest" -ForegroundColor Green
        Write-Host "  [2] gpt-5-mini          `$0.25/1M in   — fast, affordable" -ForegroundColor White
        Write-Host "  [3] gpt-5.1             `$1.25/1M in   — balanced" -ForegroundColor White
        Write-Host "  [4] gpt-5.2             `$1.75/1M in   — premium reasoning" -ForegroundColor White
        Write-Host ""
        $modelChoice = Read-Host "  Pick [1/2/3/4] (default: 1)"
        switch ($modelChoice) {
            "2" { $model = "gpt-5-mini" }
            "3" { $model = "gpt-5.1" }
            "4" { $model = "gpt-5.2" }
            default { $model = "gpt-5-nano" }
        }
    }
    "anthropic" {
        Write-Host "  [1] claude-haiku-4-5    `$1.00/1M in   — fast, cheapest" -ForegroundColor Green
        Write-Host "  [2] claude-sonnet-4-5   `$3.00/1M in   — balanced" -ForegroundColor White
        Write-Host "  [3] claude-opus-4-5     `$5.00/1M in   — most capable" -ForegroundColor White
        Write-Host ""
        $modelChoice = Read-Host "  Pick [1/2/3] (default: 1)"
        switch ($modelChoice) {
            "2" { $model = "claude-sonnet-4-5-20250514" }
            "3" { $model = "claude-opus-4-5-20250120" }
            default { $model = "claude-haiku-4-5-20251001" }
        }
    }
    "google" {
        Write-Host "  [1] gemini-3-flash      `$0.50/1M in   — latest gen, fast" -ForegroundColor Green
        Write-Host "  [2] gemini-2.5-flash     `$0.30/1M in   — stable workhorse" -ForegroundColor White
        Write-Host "  [3] gemini-2.5-flash-lite `$0.10/1M in  — ultra-cheap" -ForegroundColor White
        Write-Host "  [4] gemini-2.5-pro       `$1.25/1M in   — most capable" -ForegroundColor White
        Write-Host ""
        $modelChoice = Read-Host "  Pick [1/2/3/4] (default: 1)"
        switch ($modelChoice) {
            "2" { $model = "gemini-2.5-flash" }
            "3" { $model = "gemini-2.5-flash-lite" }
            "4" { $model = "gemini-2.5-pro" }
            default { $model = "gemini-3-flash" }
        }
    }
}
Write-Host "  ✓ Selected: $model" -ForegroundColor Green

# ──────────────────────────────────────
# 5. FEATURE CONFIGURATION
# ──────────────────────────────────────
Write-Host ""
Write-Host "Feature Configuration" -ForegroundColor White
Write-Host "  Choose which output features to enable." -ForegroundColor DarkGray
Write-Host "  Change later with: ai config" -ForegroundColor DarkGray
Write-Host ""

function Ask-Feature {
    param([string]$Desc, [bool]$Default)
    $defaultStr = if ($Default) { "Y/n" } else { "y/N" }
    $answer = Read-Host "  $($Desc.PadRight(22)) [$defaultStr]"
    if ([string]::IsNullOrEmpty($answer)) { return $Default }
    return $answer -match '^[Yy]'
}

$featFunfact = Ask-Feature "Linux fun facts"       $true
$featLinus = Ask-Feature "Linus Torvalds quotes" $true
$featAscii = Ask-Feature "ASCII art"             $true
$featRoast = Ask-Feature "Roast mode 🔥"         $false
$featSelfImprove = Ask-Feature "Self-improvement tips"  $true

# ──────────────────────────────────────
# 6. WRITE CONFIG
# ──────────────────────────────────────
$config = @{
    provider     = $provider
    model        = $model
    features     = @{
        funfact      = $featFunfact
        linus_quotes = $featLinus
        ascii_art    = $featAscii
        roast        = $featRoast
        self_improve = $featSelfImprove
    }
    conversation = @{
        buffer_size     = 3
        timeout_seconds = 1800
    }
}

$config | ConvertTo-Json -Depth 3 | Set-Content $ConfigFile
Write-Host ""
Write-Host "✓ Config saved to $ConfigFile" -ForegroundColor Green

# ──────────────────────────────────────
# 7. SUMMARY
# ──────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         Installation Complete         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Provider:  $provider" -ForegroundColor Cyan
Write-Host "  Model:     $model" -ForegroundColor Cyan
Write-Host "  Features:  funfact=$featFunfact  linus=$featLinus  ascii=$featAscii  roast=$featRoast"
Write-Host ""
Write-Host "  Reload your shell or run:" -ForegroundColor White
Write-Host "    . $InstallFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Commands:" -ForegroundColor White
Write-Host "    ai <what you want>         Natural language → commands" -ForegroundColor DarkGray
Write-Host "    ask                        Interactive mode" -ForegroundColor DarkGray
Write-Host "    ai config                  View/edit configuration" -ForegroundColor DarkGray
Write-Host "    ai model <provider>        Switch AI provider" -ForegroundColor DarkGray
Write-Host "    ai history                 View history" -ForegroundColor DarkGray
Write-Host "    ai forget                  Wipe memory" -ForegroundColor DarkGray
Write-Host ""
