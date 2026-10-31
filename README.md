# uim

機能がほとんどない vim クローンです。tree-sitter でシンタックスハイライトします。

macOS（Apple Silicon）と Linux（x64・arm64）で動きます。

## インストール

```bash
curl -fsSL https://raw.githubusercontent.com/minor-mn/uim/main/scripts/install.sh | sh
```

`~/.local/share/uim` に置かれ、`~/.local/bin/uim` から起動できます。sudo は要りません。

消すとき（`~/.config/uim` の color.json5 は残します）:

```bash
curl -fsSL https://raw.githubusercontent.com/minor-mn/uim/main/scripts/uninstall.sh | sh
```

## できること

| キー | 動作 |
|---|---|
| `i` `a` | 挿入モード（Esc で戻る） |
| `v` | 範囲選択 |
| `y` `yy` | コピー |
| `d` `dd` | 削除 |
| `p` | ペースト |
| `u` `Ctrl-r` | アンドゥ・リドゥ |
| 矢印・PageUp・PageDown | 移動 |
| `:w` `:w!` `:q` `:q!` `:wq` | 保存・終了 |

[fm-ee2e](https://github.com/minor-mn/fm-ee2e-swift) の中で動かすと、ローカルと SSH の先（2段目も）の uim どうしで、コピーした内容を `p` で貼れます。

## 色

`~/.config/uim/color.json5` で変えられます。書き方はファイルの先頭にあります。書かなかった色は既定のまま（[config/color.json5](config/color.json5)）です。

対応している言語は [lib/src/languages.dart](lib/src/languages.dart) にあります。

## ビルド

Dart 3.10 以降と C コンパイラーが要ります。

```bash
dart build cli -t bin/uim.dart
```

`build/cli/<OS>_<CPU>/bundle/bin/uim` ができます。隣の `lib/` も一緒に使うので、bundle ごと動かしてください。

## リリース

`v` から始まるタグ（`v1.0.0` など）を push すると、GitHub Actions が各 OS 向けにビルドして Release に添付します。

## ライセンス

`third_party/` の tree-sitter と各言語の文法は、それぞれのフォルダーの LICENSE に従います。
