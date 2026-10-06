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
$model = "gpt-6-sol"

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
        Write-Host "  [1] gpt-6-sol           `$2.00/`$10.00 per 1M  — smart + fast (recommended)" -ForegroundColor Green
        Write-Host "  [2] gpt-6-luna          `$0.10/`$0.50  per 1M  — nearly as fast, ~20x cheaper" -ForegroundColor White
        Write-Host "  [3] gpt-5.4-mini        `$0.75/`$4.50  per 1M  — fastest, older generation" -ForegroundColor White
        Write-Host "  [4] gpt-6.1-sol         `$2.00/`$10.00 per 1M  — always reasons: smarter, slower" -ForegroundColor White
        Write-Host ""
        $modelChoice = Read-Host "  Pick [1/2/3/4] (default: 1)"
        switch ($modelChoice) {
            "2" { $model = "gpt-6-luna" }
            "3" { $model = "gpt-5.4-mini" }
            "4" { $model = "gpt-6.1-sol" }
            default { $model = "gpt-6-sol" }
        }
    }
    "anthropic" {
        Write-Host "  [1] claude-sonnet-5-5   `$2.00/`$10.00 per 1M  — smart, thinking off for speed (recommended)" -ForegroundColor Green
        Write-Host "  [2] claude-haiku-4-5    `$1.00/`$5.00  per 1M  — fastest, cheapest" -ForegroundColor White
        Write-Host "  [3] claude-opus-5-5     `$4.00/`$20.00 per 1M  — most capable, always thinks (slower)" -ForegroundColor White
        Write-Host ""
        $modelChoice = Read-Host "  Pick [1/2/3] (default: 1)"
        switch ($modelChoice) {
            "2" { $model = "claude-haiku-4-5" }
            "3" { $model = "claude-opus-5-5" }
            default { $model = "claude-sonnet-5-5" }
        }
    }
    "google" {
        Write-Host "  [1] gemini-flash-latest       — Google's newest Flash (recommended)" -ForegroundColor Green
        Write-Host "  [2] gemini-flash-lite-latest  — newest Flash-Lite, cheapest" -ForegroundColor White
        Write-Host ""
        $modelChoice = Read-Host "  Pick [1/2] (default: 1)"
        switch ($modelChoice) {
            "2" { $model = "gemini-flash-lite-latest" }
            default { $model = "gemini-flash-latest" }
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
    provider         = $provider
    model            = $model
    reasoning_effort = "none"
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
