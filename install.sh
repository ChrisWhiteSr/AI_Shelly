#!/bin/bash
# AI Shelly installer

set -e

INSTALL_PATH="$HOME/.ai-shell.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/ai-shell.sh"

echo "=== AI Shelly Installer ==="
echo ""

# --- Check and install required dependencies ---
missing=()
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required dependencies: ${missing[*]}"

    # Detect package manager
    if command -v apt &>/dev/null; then
        pkg_mgr="sudo apt install -y"
    elif command -v dnf &>/dev/null; then
        pkg_mgr="sudo dnf install -y"
    elif command -v pacman &>/dev/null; then
        pkg_mgr="sudo pacman -S --noconfirm"
    elif command -v zypper &>/dev/null; then
        pkg_mgr="sudo zypper install -y"
    elif command -v brew &>/dev/null; then
        pkg_mgr="brew install"
    else
        echo "Error: Could not detect package manager."
        echo "Please install manually: ${missing[*]}"
        exit 1
    fi

    read -p "Install ${missing[*]} using '$pkg_mgr'? [Y/n] " confirm
    if [ -z "$confirm" ] || [ "$confirm" = "Y" ] || [ "$confirm" = "y" ]; then
        $pkg_mgr "${missing[@]}"
        echo "Dependencies installed."
    else
        echo "Error: ${missing[*]} required. Install them and re-run."
        exit 1
    fi
fi
echo ""

# Copy script to home directory
cp "$SOURCE_FILE" "$INSTALL_PATH"
echo "Installed to $INSTALL_PATH"

# Detect shell config file
SHELL_RC=""
if [ -n "$ZSH_VERSION" ] || [ "$SHELL" = "$(which zsh 2>/dev/null)" ]; then
    SHELL_RC="$HOME/.zshrc"
else
    SHELL_RC="$HOME/.bashrc"
fi

# Add source line if not already present
SOURCE_LINE="source \"$INSTALL_PATH\""
if ! grep -qF ".ai-shell.sh" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# AI Shelly - natural language shell assistant" >> "$SHELL_RC"
    echo "$SOURCE_LINE" >> "$SHELL_RC"
    echo "Added source line to $SHELL_RC"
else
    echo "Source line already in $SHELL_RC (skipped)"
fi

# Set up API key directory
KEY_DIR="$HOME/.config/ai-shell"
KEY_FILE="$KEY_DIR/api-key"
mkdir -p "$KEY_DIR"

if [ ! -f "$KEY_FILE" ]; then
    echo ""
    echo "No API key found."
    echo "Get one from https://console.anthropic.com/"
    read -p "Paste your Anthropic API key (or press Enter to skip): " api_key
    if [ -n "$api_key" ]; then
        echo "$api_key" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        echo "API key saved to $KEY_FILE"
    else
        echo "Skipped. Add your key later:"
        echo "  echo 'sk-ant-...' > $KEY_FILE"
    fi
else
    echo "API key already configured."
fi

echo ""
echo "Done! Restart your shell or run:"
echo "  source $SHELL_RC"
echo ""
echo "Usage:"
echo "  ai <what you want to do>       # natural language commands"
echo "  ask                             # interactive mode"
echo "  <cmd> | ai <question>           # pipe mode"
echo "  ai recall <search>              # search memory"
echo "  ai history                      # view history"
echo "  ai forget                       # wipe memory"
echo ""
echo "Optional: export AI_ROAST=1 to enable roast mode"
