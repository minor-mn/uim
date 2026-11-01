#!/bin/sh
# uim をインストールする（macOS の Apple Silicon と、Linux の x64・arm64）。
#   curl -fsSL https://raw.githubusercontent.com/minor-mn/uim/main/scripts/install.sh | sh
# 横に uim/ がなければ（curl から動かしたとき）、この OS と CPU 向けの最新の Release を取ってきて、
# その中の install.sh を動かす。
# 横に uim/ があれば（tar.gz の中）、~/.local/share/uim に置いて、~/.local/bin/uim からつなぐ。
# すでにある ~/.config/uim/color.json5 は上書きしない。
set -eu
here=$(dirname "$0")

# curl から sh に渡したときは $0 が sh になり、here がカレントディレクトリになるので、
# ファイル名が install.sh のときだけ tar.gz の中とみなす。
if [ "$(basename "$0")" != install.sh ] || [ ! -d "$here/uim" ]; then
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) echo "この OS には対応していません: $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) cpu=arm64 ;;
    x86_64 | amd64) cpu=x64 ;;
    *) echo "この CPU には対応していません: $(uname -m)" >&2; exit 1 ;;
  esac
  if [ "$os-$cpu" = macos-x64 ]; then
    echo "Intel の Mac には対応していません。" >&2
    exit 1
  fi
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  echo "ダウンロードしています…"
  curl -fL --progress-bar --connect-timeout 15 --retry 3 -o "$work/uim.tar.gz" "https://github.com/minor-mn/uim/releases/latest/download/uim-$os-$cpu.tar.gz"
  tar -xzf "$work/uim.tar.gz" -C "$work"
  sh "$work/uim/install.sh"
  exit
fi

cd "$here"
share="$HOME/.local/share/uim"
bin="$HOME/.local/bin"
config="$HOME/.config/uim"

rm -rf "$share"
mkdir -p "$(dirname "$share")" "$bin" "$config"
cp -R uim "$share"
ln -sf "$share/bin/uim" "$bin/uim"
if [ "$(uname -s)" = Darwin ]; then
  xattr -dr com.apple.quarantine "$share" 2>/dev/null || true
fi

if [ -e "$config/color.json5" ]; then
  echo "$config/color.json5 はそのままにしました。"
else
  cp color.json5 "$config/"
fi

echo "インストールしました: $bin/uim"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "$bin が PATH に入っていないので、uim と打つだけでは起動できません。フルパスで指定してください。" ;;
esac
echo "fm-ee2e から使うときは、シェルの設定に次の1行を足してください:"
echo "  export EDITOR=\"\$HOME/.local/bin/uim\""
