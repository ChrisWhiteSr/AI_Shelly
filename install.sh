#!/bin/bash
# AI Shelly — Smart Installer
# Detects OS, shell, installs deps, configures features

set -e

INSTALL_PATH="$HOME/.ai-shell.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/ai-shell.sh"
CONFIG_DIR="$HOME/.config/ai-shell"
CONFIG_FILE="$CONFIG_DIR/config.json"
KEY_FILE="$CONFIG_DIR/api-key"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[0;90m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       AI Shelly — Installer          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
echo ""

# ──────────────────────────────────────
# 1. DETECT OPERATING SYSTEM
# ──────────────────────────────────────
detect_os() {
    local os_type=$(uname -s 2>/dev/null)
    case "$os_type" in
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        Darwin*)  echo "macos" ;;
        CYGWIN*)  echo "cygwin" ;;
        MINGW*|MSYS*) echo "gitbash" ;;
        *)        echo "unknown" ;;
    esac
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2
    elif [ "$(uname -s)" = "Darwin" ]; then
        echo "macOS $(sw_vers -productVersion 2>/dev/null)"
    else
        uname -s 2>/dev/null
    fi
}

detect_shell() {
    local shell_name=$(basename "$SHELL" 2>/dev/null)
    case "$shell_name" in
        zsh)  echo "zsh" ;;
        fish) echo "fish" ;;
        *)    echo "bash" ;;
    esac
}

OS_TYPE=$(detect_os)
DISTRO=$(detect_distro)
SHELL_TYPE=$(detect_shell)

echo -e "${CYAN}Detected environment:${RESET}"
echo -e "  OS:    ${GREEN}$OS_TYPE${RESET} ($DISTRO)"
echo -e "  Shell: ${GREEN}$SHELL_TYPE${RESET}"
echo ""

# ──────────────────────────────────────
# 2. CHECK & INSTALL DEPENDENCIES
# ──────────────────────────────────────
missing=()
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${YELLOW}Missing dependencies: ${missing[*]}${RESET}"

    pkg_mgr=""
    case "$OS_TYPE" in
        linux|wsl)
            if command -v apt &>/dev/null; then pkg_mgr="sudo apt install -y"
            elif command -v dnf &>/dev/null; then pkg_mgr="sudo dnf install -y"
            elif command -v pacman &>/dev/null; then pkg_mgr="sudo pacman -S --noconfirm"
            elif command -v zypper &>/dev/null; then pkg_mgr="sudo zypper install -y"
            elif command -v apk &>/dev/null; then pkg_mgr="sudo apk add"
            fi
            ;;
        macos)
            if command -v brew &>/dev/null; then pkg_mgr="brew install"
            else
                echo -e "${RED}Homebrew not found. Install it first:${RESET}"
                echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                exit 1
            fi
            ;;
        gitbash|cygwin)
            echo -e "${RED}Please install ${missing[*]} manually (e.g. via chocolatey or scoop).${RESET}"
            exit 1
            ;;
    esac

    if [ -n "$pkg_mgr" ]; then
        read -p "Install ${missing[*]} using '$pkg_mgr'? [Y/n] " confirm
        if [ -z "$confirm" ] || [[ "$confirm" =~ ^[Yy] ]]; then
            $pkg_mgr "${missing[@]}"
            echo -e "${GREEN}Dependencies installed.${RESET}"
        else
            echo -e "${RED}Cannot continue without ${missing[*]}.${RESET}"
            exit 1
        fi
    fi
fi

# ──────────────────────────────────────
# 3. INSTALL SCRIPT
# ──────────────────────────────────────
cp "$SOURCE_FILE" "$INSTALL_PATH"
echo -e "${GREEN}✓${RESET} Installed to ${BOLD}$INSTALL_PATH${RESET}"

# ──────────────────────────────────────
# 4. HOOK INTO SHELL RC
# ──────────────────────────────────────
SHELL_RC=""
case "$SHELL_TYPE" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    *)    SHELL_RC="$HOME/.bashrc" ;;
esac

SOURCE_LINE="source \"$INSTALL_PATH\""
if [ "$SHELL_TYPE" = "fish" ]; then
    SOURCE_LINE="source $INSTALL_PATH"
fi

if ! grep -qF ".ai-shell.sh" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# AI Shelly — natural language shell assistant" >> "$SHELL_RC"
    echo "$SOURCE_LINE" >> "$SHELL_RC"
    echo -e "${GREEN}✓${RESET} Added source line to ${BOLD}$SHELL_RC${RESET}"
else
    echo -e "${DIM}  Source line already in $SHELL_RC (skipped)${RESET}"
fi

# ──────────────────────────────────────
# 5. API KEY SETUP (with provider detection)
# ──────────────────────────────────────
mkdir -p "$CONFIG_DIR"

detect_provider_from_key() {
    local key="$1"
    if [[ "$key" == sk-ant-* ]]; then
        echo "anthropic"
    elif [[ "$key" == sk-* ]]; then
        echo "openai"
    elif [[ "$key" == AI* ]]; then
        echo "google"
    else
        echo "anthropic"
    fi
}

default_model_for_provider() {
    case "$1" in
        anthropic) echo "claude-haiku-4-5-20251001" ;;
        openai)    echo "gpt-5-nano" ;;
        google)    echo "gemini-3-flash" ;;
        *)         echo "claude-haiku-4-5-20251001" ;;
    esac
}

PROVIDER="anthropic"
MODEL=""

if [ -f "$KEY_FILE" ]; then
    echo -e "${DIM}  API key already configured.${RESET}"
    PROVIDER=$(detect_provider_from_key "$(cat "$KEY_FILE")")
else
    echo ""
    echo -e "${BOLD}API Key Setup${RESET}"
    echo -e "${DIM}  Supported: Anthropic (sk-ant-...), OpenAI (sk-...), Google (AI...)${RESET}"
    echo -e "${DIM}  Get one from: https://console.anthropic.com/${RESET}"
    echo ""
    read -p "Paste your API key (or press Enter to skip): " api_key
    if [ -n "$api_key" ]; then
        echo "$api_key" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        PROVIDER=$(detect_provider_from_key "$api_key")
        echo -e "${GREEN}✓${RESET} API key saved (detected provider: ${BOLD}$PROVIDER${RESET})"
    else
        echo -e "${YELLOW}  Skipped. Add your key later:${RESET}"
        echo "    echo 'sk-ant-...' > $KEY_FILE"
    fi
fi

MODEL=$(default_model_for_provider "$PROVIDER")

# ──────────────────────────────────────
# 5b. MODEL SELECTION
# ──────────────────────────────────────
echo ""
echo -e "${BOLD}Model Selection${RESET} (provider: ${CYAN}$PROVIDER${RESET})"
echo -e "${DIM}  Choose your model. Switch anytime with: ai model${RESET}"
echo ""

case "$PROVIDER" in
    openai)
        echo -e "  ${GREEN}[1]${RESET} gpt-5-nano          \$0.05/1M in  — ultra-cheap, fastest"
        echo -e "  [2] gpt-5-mini          \$0.25/1M in  — fast, affordable"
        echo -e "  [3] gpt-5.1             \$1.25/1M in  — balanced"
        echo -e "  [4] gpt-5.2             \$1.75/1M in  — premium reasoning"
        echo ""
        read -p "  Pick [1/2/3/4] (default: 1): " model_choice
        case "$model_choice" in
            2) MODEL="gpt-5-mini" ;;
            3) MODEL="gpt-5.1" ;;
            4) MODEL="gpt-5.2" ;;
            *) MODEL="gpt-5-nano" ;;
        esac
        ;;
    anthropic)
        echo -e "  ${GREEN}[1]${RESET} claude-haiku-4-5    \$1.00/1M in  — fast, cheapest"
        echo -e "  [2] claude-sonnet-4-5   \$3.00/1M in  — balanced"
        echo -e "  [3] claude-opus-4-5     \$5.00/1M in  — most capable"
        echo ""
        read -p "  Pick [1/2/3] (default: 1): " model_choice
        case "$model_choice" in
            2) MODEL="claude-sonnet-4-5-20250514" ;;
            3) MODEL="claude-opus-4-5-20250120" ;;
            *) MODEL="claude-haiku-4-5-20251001" ;;
        esac
        ;;
    google)
        echo -e "  ${GREEN}[1]${RESET} gemini-3-flash      \$0.50/1M in  — latest gen, fast"
        echo -e "  [2] gemini-2.5-flash     \$0.30/1M in  — stable workhorse"
        echo -e "  [3] gemini-2.5-flash-lite \$0.10/1M in — ultra-cheap"
        echo -e "  [4] gemini-2.5-pro       \$1.25/1M in  — most capable"
        echo ""
        read -p "  Pick [1/2/3/4] (default: 1): " model_choice
        case "$model_choice" in
            2) MODEL="gemini-2.5-flash" ;;
            3) MODEL="gemini-2.5-flash-lite" ;;
            4) MODEL="gemini-2.5-pro" ;;
            *) MODEL="gemini-3-flash" ;;
        esac
        ;;
esac

echo -e "  ${GREEN}✓${RESET} Selected: ${BOLD}$MODEL${RESET}"

# ──────────────────────────────────────
# 6. FEATURE CONFIGURATION
# ──────────────────────────────────────
echo ""
echo -e "${BOLD}Feature Configuration${RESET}"
echo -e "${DIM}  Choose which output features to enable.${RESET}"
echo -e "${DIM}  You can change these later with: ai config${RESET}"
echo ""

ask_feature() {
    local name="$1"
    local desc="$2"
    local default="$3"
    local prompt_default="Y/n"
    [ "$default" = "false" ] && prompt_default="y/N"
    read -p "  $(printf '%-22s' "$desc") [$prompt_default]: " answer
    if [ -z "$answer" ]; then
        echo "$default"
    elif [[ "$answer" =~ ^[Yy] ]]; then
        echo "true"
    else
        echo "false"
    fi
}

FEAT_FUNFACT=$(ask_feature "funfact" "Linux fun facts" "true")
FEAT_LINUS=$(ask_feature "linus_quotes" "Linus Torvalds quotes" "true")
FEAT_ASCII=$(ask_feature "ascii_art" "ASCII art" "true")
FEAT_ROAST=$(ask_feature "roast" "Roast mode 🔥" "false")
FEAT_SELF_IMPROVE=$(ask_feature "self_improve" "Self-improvement tips" "true")

# ──────────────────────────────────────
# 7. WRITE CONFIG FILE
# ──────────────────────────────────────
jq -n \
    --arg provider "$PROVIDER" \
    --arg model "$MODEL" \
    --argjson funfact "$FEAT_FUNFACT" \
    --argjson linus_quotes "$FEAT_LINUS" \
    --argjson ascii_art "$FEAT_ASCII" \
    --argjson roast "$FEAT_ROAST" \
    --argjson self_improve "$FEAT_SELF_IMPROVE" \
    --argjson conv_buffer 3 \
    --argjson conv_timeout 1800 \
    '{
        provider: $provider,
        model: $model,
        features: {
            funfact: $funfact,
            linus_quotes: $linus_quotes,
            ascii_art: $ascii_art,
            roast: $roast,
            self_improve: $self_improve
        },
        conversation: {
            buffer_size: $conv_buffer,
            timeout_seconds: $conv_timeout
        }
    }' > "$CONFIG_FILE"

echo ""
echo -e "${GREEN}✓${RESET} Config saved to ${BOLD}$CONFIG_FILE${RESET}"

# ──────────────────────────────────────
# 8. SUMMARY
# ──────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Installation Complete         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Provider:  ${CYAN}$PROVIDER${RESET}"
echo -e "  Model:     ${CYAN}$MODEL${RESET}"
echo -e "  Features:  funfact=$FEAT_FUNFACT  linus=$FEAT_LINUS  ascii=$FEAT_ASCII  roast=$FEAT_ROAST"
echo ""
echo -e "  Restart your shell or run:"
echo -e "    ${YELLOW}source $SHELL_RC${RESET}"
echo ""
echo -e "  ${BOLD}Commands:${RESET}"
echo -e "    ai <what you want>         Natural language → commands"
echo -e "    ask                        Interactive mode"
echo -e "    <cmd> | ai <question>      Pipe mode"
echo -e "    ai config                  View/edit configuration"
echo -e "    ai model <provider>        Switch AI provider"
echo -e "    ai recall <search>         Search memory"
echo -e "    ai history                 View history"
echo -e "    ai forget                  Wipe memory"
echo ""
