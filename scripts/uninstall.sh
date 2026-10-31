#!/bin/sh
# uim を消す。
#   curl -fsSL https://raw.githubusercontent.com/minor-mn/uim/main/scripts/uninstall.sh | sh
# ~/.local/share/uim と ~/.local/bin/uim を消す。~/.config/uim（color.json5）は残す。
set -eu
rm -rf "$HOME/.local/share/uim"
rm -f "$HOME/.local/bin/uim"
echo "アンインストールしました。$HOME/.config/uim の color.json5 は残してあります。"
