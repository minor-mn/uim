# uim

機能がほとんどない vim クローンです。tree-sitter でシンタックスハイライトします。

macOS（Apple Silicon）と Linux（x64・arm64）で動きます。

## インストール

```bash
curl -fsSL https://raw.githubusercontent.com/minor-mn/uim/main/scripts/install.sh | sh
```

`~/.local/share/uim` に置かれ、`~/.local/bin/uim` から起動できます。sudo は要りません。

`~/.bash_profile` など、使っているシェルの設定ファイルに次の2行を足します。1行目は、uim をいつものエディター（fm-ee2e などから開くもの）にするときだけ要ります。

```bash
export EDITOR="$HOME/.local/bin/uim"
export PATH="$HOME/.local/bin:$PATH"
```

足したら、読み込み直します。

```bash
source ~/.bash_profile
```

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

## 文字コードと改行コード

ファイルを開くときに判定し、保存するときは開いたときと同じ文字コード・改行コード・BOM で書き戻します。今のファイルの状態は、画面の一番下の行の右端に `UTF-8 / LF` のように出ます。

| 文字コード | 判定のしかた |
|---|---|
| UTF-8 | UTF-8 として正しく読めるとき（BOM なし） |
| UTF-8 BOM | 先頭が `EF BB BF` |
| UTF-16LE | 先頭が `FF FE`（BOM 付きのみ） |
| UTF-16BE | 先頭が `FE FF`（BOM 付きのみ） |
| UTF-32LE | 先頭が `FF FE 00 00`（BOM 付きのみ） |
| UTF-32BE | 先頭が `00 00 FE FF`（BOM 付きのみ） |
| CP932 | UTF-8 として読めず、CP932（Windows の Shift_JIS）として正しく読めるとき |

- どれにも当てはまらないファイルは、UTF-8 として読み、読めないバイトは置き換えます。
- CP932 のファイルに、CP932 で表せない文字（絵文字など）を入れると、保存せずに `E513` のエラーを出します。

| 改行コード | |
|---|---|
| LF | `\n` |
| CRLF | `\r\n` |
| CR | `\r` |

- ファイルの中で最初に出てくる改行で判定します。改行がないファイルと新しいファイルは LF です。
- 改行コードが混ざっていても表示は崩れませんが、保存すると判定した1種類にそろいます。

## 色

`~/.config/uim/color.json5` で変えられます。書き方はファイルの先頭にあります。書かなかった色は既定のまま（[config/color.json5](config/color.json5)）です。

対応している言語は [lib/src/languages.dart](lib/src/languages.dart) にあります。

## ビルド

Dart 3.10 以降と C コンパイラーが要ります。

```bash
dart build cli -t bin/uim.dart
```

`build/cli/<OS>_<CPU>/bundle/bin/uim` ができます。隣の `lib/` も一緒に使うので、bundle ごと動かしてください。

## 技術情報: 共有レジスタ（OSC 7520）

[fm-ee2e](https://github.com/minor-mn/fm-ee2e-swift) の中で動かした uim どうしで、ヤンクした内容を受け渡す仕組みです。ローカル、SSH の先、SSH の2段目のどの組み合わせでも同じように動きます。

### 考え方

- uim は、どこで動いていても標準入出力の先は fm-ee2e の枠の中の端末です。SSH の場合も、ssh は端末の入出力をバイト列のまま中継するだけなので（2段目も同じ）、uim が書いたバイト列は fm-ee2e の端末まで届き、fm-ee2e が書いたバイト列は uim の標準入力に届きます。
- そこで、fm-ee2e の端末に「最後にヤンクされた内容」を1つ置き、uim はエスケープシーケンスでそれを読み書きします。fm-ee2e がすべての枠で共有するので、別々の枠（別々のホスト）の uim どうしでも受け渡せます。
- 端末の機能として標準の OSC 52（クリップボード）は、Mac のクリップボードを書き換えてしまい、行単位か文字単位かも伝わりません。vim のヤンクとクリップボードが別であることを保つため、uim と fm-ee2e の間だけで使う OSC 7520 を使っています。

### やりとりの形式

```
書き込み  uim → fm-ee2e:  ESC ] 7520 ; set ; line|char ; <Base64> BEL
読み出し  uim → fm-ee2e:  ESC ] 7520 ; get BEL
返事      fm-ee2e → uim:  ESC ] 7520 ; line|char ; <Base64> BEL
                          ESC ] 7520 ; empty BEL（まだ何もない）
```

- `line` は行単位（`yy` `dd`）、`char` は文字単位（`v` での `y` `d`）です。
- 中身は UTF-8 のテキストを Base64 にしたものです。Base64 には `;` も制御文字も入らないので、改行や `;` を含むテキストでもそのまま送れます。
- 行単位は各行の末尾に改行を付けて1つにつなぎ、受け取る側は末尾の改行を1つ外して行に分けます。文字単位は改行でつなぐだけです。
- 終端は BEL（`\x07`）です。fm-ee2e は ST（`ESC \`）で終えたものも受け付けます。

### ヤンクしたとき（uim → fm-ee2e）

1. `y` `yy` `d` `dd` でレジスタに入れるたびに、uim は `set` を標準出力に書きます（`lib/editor.dart` の `_setRegister`）。画面の描画と同じ出力に混ざりますが、端末は OSC を文字として表示しません。
2. SSH の先なら、ssh がそのまま手元へ中継します。
3. fm-ee2e の端末（`ShellTerminal`）は、OSC の中身を読んで `osc` に渡し、番号が 7520 なら `SharedRegister.handle` が中身を Base64 からデコードして、アプリ全体で1つの `SharedRegister.content` に置きます。形が合わないもの（種類が違う、Base64 として読めない）は無視します。
4. fm-ee2e の内容はアプリを終えるまで残り、どの枠から読んでも同じです。Mac のクリップボードには触りません。

### 貼り付けたとき（fm-ee2e → uim）

1. `p` を押すと、uim は `get` を書き、返事が来るまで貼り付けを保留します（`_requestPaste`）。
2. fm-ee2e の端末は `get` を受け取ると、返事の文字列を作り、端末の問い合わせ（カーソル位置など）に答えるときと同じ `onResponse` で、そのプログラムの入力に書き込みます。SSH の先なら ssh がそれを中継します。
3. uim の入力は `KeyParser`（`lib/terminal.dart`）がキーに分けます。`ESC ] 7520 ;` で始まる OSC は、中身ごと1つの特別なキー（`<Register>` + 中身）にします。返事が長くて何回かに分かれて届いても、終端が来るまでためてからつなぎます。
4. エディターはそのキーを受け取ると、中身をデコードして自分のレジスタに入れ、保留していた貼り付けをします。`empty` なら自分のレジスタのまま貼ります。
5. 保留している間に打ったキーはためておき、貼ったあとに順に処理します。`p` のすぐあとに `:wq` を打っても、貼ってから保存されます。

どの uim もヤンクのたびに書き込むので、fm-ee2e にあるのは常に「どこかの uim が最後にヤンクしたもの」です。`p` はそれを貼るので、ホスト B で `yy` したものを、ホスト A でもローカルでも貼れます。

### fm-ee2e の外で動かしたとき

- uim は起動時に `get` を1回送って、返事が来るかで fm-ee2e の中かどうかを確かめます。
- 2秒以内に返事がなければ外とみなし、以後は `set` も `get` も送らず、自分のレジスタだけを使います。普通の端末で `p` を押しても待ちません。
- `p` を押してから2秒たっても返事がないときも、自分のレジスタから貼ります（`bin/uim.dart` のタイマーと `registerTimedOut`）。問い合わせごとに番号を振り、古い問い合わせのタイマーが新しい待ちを打ち切らないようにしています。

### 大きさの上限

- fm-ee2e の端末は、ふだん OSC の中身を4096文字で打ち切りますが、`7520;` で始まるものだけは16MB（文字数）まで受け付けます（`SharedRegister.limit`）。Base64 に直す前のテキストで約12MB です。
- 上限を超えたヤンクは途中で切れて Base64 として読めないので、共有されません。そのヤンクをした uim の中では、自分のレジスタから貼れます。
- uim 側には上限を設けていません。

### 実装の場所

| | uim | fm-ee2e |
|---|---|---|
| 書き込みを送る・受ける | `lib/editor.dart` の `_setRegister` | `TUI/ShellTerminal.swift` の `osc` → `TUI/SharedRegister.swift` の `handle` |
| 問い合わせる・答える | `lib/editor.dart` の `_requestPaste` | `SharedRegister.handle` → `ShellTerminal.onResponse` |
| 返事を読む | `lib/terminal.dart` の `KeyParser`、`lib/editor.dart` の `_receiveRegister` | |
| 待ち時間 | `bin/uim.dart` の `watchRegister` | |
