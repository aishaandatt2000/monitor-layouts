#!/bin/bash
# install.sh — Set up monitor-layouts on a new machine
# Usage: bash install.sh

set -e

echo "🚀 Installing monitor-layouts..."
echo ""

# Check for Homebrew
if ! command -v brew &>/dev/null; then
  echo "❌ Homebrew is required. Install it from https://brew.sh then run this script again."
  exit 1
fi

# Install displayplacer
if ! command -v displayplacer &>/dev/null; then
  echo "📦 Installing displayplacer..."
  brew install displayplacer
else
  echo "✅ displayplacer already installed"
fi

# Install yabai
if ! command -v yabai &>/dev/null; then
  echo "📦 Installing yabai..."
  brew tap koekeishiya/formulae 2>/dev/null || true
  brew trust koekeishiya/formulae 2>/dev/null || true
  brew install yabai
else
  echo "✅ yabai already installed"
fi

# Start yabai service
echo "⚙️  Starting yabai service..."
yabai --start-service 2>/dev/null || true
sleep 2

if yabai -m query --windows &>/dev/null; then
  echo "✅ yabai is running"
else
  echo "⚠️  yabai started but not responding yet — it may need Accessibility permission."
  echo "   Go to: System Settings → Privacy & Security → Accessibility"
  echo "   Add and enable your Terminal app, then run: yabai --start-service"
fi

# Make scripts executable
chmod +x "$(dirname "$0")/capture.sh" "$(dirname "$0")/restore.sh"
echo "✅ Scripts are executable"

# Create config directory
mkdir -p "$HOME/.config/monitor-layouts/layouts"
echo "✅ Config directory ready: ~/.config/monitor-layouts/"

echo ""
echo "✅ Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Connect your first monitor and arrange your windows"
echo "  2. Run: ./capture.sh"
echo "  3. When you reconnect that monitor later, run: ./restore.sh"
echo ""
echo "Repeat step 1-2 for each monitor you use."
