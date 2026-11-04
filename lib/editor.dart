import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'colors.dart';
import 'encoding.dart';
import 'highlight.dart';
import 'history.dart';
import 'substitute.dart';
import 'terminal.dart';
import 'width.dart';

enum Mode { normal, insert, visual, command, confirm }

/// A line of text as Unicode code points. Lines are never mutated in place,
/// so buffer snapshots can share them.
typedef Line = List<int>;

class Pos implements Comparable<Pos> {
  const Pos(this.row, this.col);

  final int row;
  final int col;

  @override
  int compareTo(Pos other) =>
      row != other.row ? row - other.row : col - other.col;
}

class _Register {
  _Register(this.parts, {required this.linewise});

  /// Linewise: whole lines. Charwise: pieces of text separated by newlines.
  final List<Line> parts;
  final bool linewise;
}

class _Change {
  _Change(
    this.id,
    this.before,
    this.after,
    this.cursorBefore,
    this.cursorAfter,
  );

  final int id;
  final List<Line> before;
  final List<Line> after;
  final Pos cursorBefore;
  final Pos cursorAfter;
}

/// A `:s` without `g` going through its matches, asking about each one.
class _Confirm {
  _Confirm(
    this.sub,
    this.regex,
    this.row,
    this.lastRow,
    this.before,
    this.cursorBefore,
  );

  final Substitute sub;
  final RegExp regex;

  /// Row of [match], and the last row of the range.
  int row;
  final int lastRow;

  /// Buffer and cursor before the command, for the undo entry.
  final List<Line> before;
  final Pos cursorBefore;

  /// UTF-16 offset in [row] to look for the next match from.
  int from = 0;

  /// The match being asked about.
  Match? match;
  bool found = false;
  int count = 0;
  final changedRows = <int>{};
  int lastChanged = -1;
}

class Editor {
  Editor(String? path) : this._(path, Colors.load(), History.forUser());

  Editor._(this.path, this._colors, this._history)
    : _highlighter = Highlighter.forPath(path, _colors) {
    _load();
    final error = _colors.error;
    if (error != null) _error(error);
  }

  final String? path;
  final Colors _colors;
  final History _history;
  final Highlighter? _highlighter;

  /// The lines last given to [_highlighter]. Lines are immutable, so
  /// comparing them by identity tells whether the buffer changed.
  List<Line> _highlighted = const [];

  List<Line> _lines = [<int>[]];

  /// Whether the file was empty (or did not exist) when loaded. A buffer of
  /// one empty line is then written as an empty file, as vim does.
  bool _loadedEmpty = true;

  /// Encoding and line ending of the file, kept when writing it.
  TextEncoding _encoding = TextEncoding.utf8;
  LineEnding _lineEnding = LineEnding.lf;

  int _row = 0;
  int _col = 0;

  /// Display column the cursor tries to keep when moving up and down.
  int _wantDisp = 0;

  Mode _mode = Mode.normal;
  Pos _anchor = const Pos(0, 0);

  /// `:` for an Ex command, `/` for a search.
  String _cmdPrefix = ':';
  String _cmdline = '';

  /// Cursor on the command line, in code points.
  int _cmdPos = 0;

  /// Pattern of the last `/` search, for `n` and `N`.
  RegExp? _lastSearch;

  /// Whether matches of [_lastSearch] are colored; `:noh` turns it off until
  /// the next search.
  bool _hlsearch = false;

  /// History entries read when the command line opened, oldest first.
  List<String> _historyEntries = const [];

  /// Entry shown on the command line; `_historyEntries.length` while showing
  /// what was typed.
  int _historyIndex = 0;

  /// What was typed before going through the history: only entries starting
  /// with it are shown.
  String _historyTyped = '';

  /// The `:s` asking about each match, in [Mode.confirm].
  _Confirm? _confirm;
  String _message = '';
  bool _messageIsError = false;

  /// First key of `yy` or `dd` while waiting for the second one.
  String? _pendingOp;
  _Register? _register;

  /// Buffer and cursor when insert mode started, for the undo entry.
  List<Line> _insertBefore = const [];
  Pos _insertCursor = const Pos(0, 0);

  final _undo = <_Change>[];
  final _redo = <_Change>[];
  int _nextId = 1;
  int _savedId = 0;

  int _top = 0;
  int _left = 0;

  /// Height of the text area at the last render.
  int _textRows = 1;

  bool quit = false;

  /// Writes escape sequences to the terminal; set by the main loop.
  void Function(String)? send;

  /// Whether the terminal keeps a register shared by every uim running in it
  /// (fm-ee2e, OSC 7520). Null until it replies or a request times out.
  bool? sharedRegister;

  /// Number of the latest request to the shared register, which
  /// [registerTimedOut] is called with.
  int registerRequest = 0;

  /// `p` is waiting for the shared register; keys meanwhile are queued.
  bool _waitingForRegister = false;
  final _queuedKeys = <String>[];

  bool get waitingForRegister => _waitingForRegister;

  Pos get _cursor => Pos(_row, _col);
  int get _currentId => _undo.isEmpty ? 0 : _undo.last.id;
  bool get modified => _currentId != _savedId;

  void _load() {
    final p = path;
    if (p == null) return;
    final file = File(p);
    if (!file.existsSync()) {
      _info('"$p" [New]');
      return;
    }
    final bytes = file.readAsBytesSync();
    final (text, encoding) = decodeText(bytes);
    _encoding = encoding;
    _lineEnding = detectLineEnding(text);
    final parts = splitLines(text);
    if (text.endsWith('\n') || text.endsWith('\r')) parts.removeLast();
    _lines = parts.map((s) => s.runes.toList()).toList();
    if (_lines.isEmpty) _lines.add(<int>[]);
    _loadedEmpty = text.isEmpty;
    _info('"$p" ${text.isEmpty ? 0 : parts.length}L, ${bytes.length}B');
  }

  void handleKey(String key) {
    if (key.startsWith(registerReplyKey)) {
      _receiveRegister(key.substring(registerReplyKey.length));
      return;
    }
    if (_waitingForRegister) {
      _queuedKeys.add(key);
      return;
    }
    if (key.startsWith(pasteKey)) {
      _pasteText(key.substring(pasteKey.length));
      return;
    }
    switch (_mode) {
      case Mode.normal:
        _normalKey(key);
      case Mode.insert:
        _insertKey(key);
      case Mode.visual:
        _visualKey(key);
      case Mode.command:
        _commandKey(key);
      case Mode.confirm:
        _confirmKey(key);
    }
  }

  /// Called on Ctrl-C.
  void interrupt() {
    _pendingOp = null;
    if (_mode == Mode.normal) {
      _info('Type  :q!  and press <Enter> to abandon all changes and exit uim');
    } else if (_mode == Mode.insert) {
      _leaveInsert();
    } else if (_mode == Mode.confirm) {
      // Stops asking, keeping what was replaced so far.
      _finishConfirm();
    } else {
      _mode = Mode.normal;
      _setCmdline('');
    }
  }

  void _normalKey(String key) {
    final op = _pendingOp;
    if (op != null) {
      _pendingOp = null;
      if (key == op) op == 'y' ? _yankLine() : _deleteLine();
      return;
    }
    if (_move(key)) return;
    switch (key) {
      case 'i':
        _startInsert(_col);
      case 'a':
        _startInsert(_lines[_row].isEmpty ? 0 : _col + 1);
      case 'v':
        _mode = Mode.visual;
        _anchor = _cursor;
        _message = '';
      case 'y':
        _pendingOp = 'y';
      case 'd':
        _pendingOp = 'd';
      case 'p':
        _requestPaste();
      case 'u':
        _undoChange();
      case '<C-r>':
        _redoChange();
      case ':' || '/':
        _mode = Mode.command;
        _cmdPrefix = key;
        _setCmdline('');
        _message = '';
        // Read each time, for entries added by other uims.
        _historyEntries = _history.read();
        _historyIndex = _historyEntries.length;
      case 'n':
        _searchAgain(forward: true);
      case 'N':
        _searchAgain(forward: false);
    }
  }

  void _startInsert(int col) {
    _insertBefore = List.of(_lines);
    _insertCursor = _cursor;
    _mode = Mode.insert;
    _message = '';
    _setCursor(Pos(_row, col));
  }

  void _insertKey(String key) {
    if (_move(key)) return;
    final line = _lines[_row];
    switch (key) {
      case '<Esc>':
        _leaveInsert();
      case '<CR>':
        _lines.replaceRange(_row, _row + 1, [
          line.sublist(0, _col),
          line.sublist(_col),
        ]);
        _setCursor(Pos(_row + 1, 0));
      case '<BS>':
        if (_col > 0) {
          _lines[_row] = [...line.sublist(0, _col - 1), ...line.sublist(_col)];
          _setCursor(Pos(_row, _col - 1));
        } else if (_row > 0) {
          final prev = _lines[_row - 1];
          _lines.replaceRange(_row - 1, _row + 1, [
            [...prev, ...line],
          ]);
          _setCursor(Pos(_row - 1, prev.length));
        }
      default:
        if (key.runes.length != 1) return;
        _lines[_row] = [
          ...line.sublist(0, _col),
          ...key.runes,
          ...line.sublist(_col),
        ];
        _setCursor(Pos(_row, _col + 1));
    }
  }

  void _leaveInsert() {
    _mode = Mode.normal;
    _setCursor(Pos(_row, _col - 1));
    if (!_sameLines(_insertBefore, _lines)) {
      _record(_insertBefore, _insertCursor);
    }
    _insertBefore = const [];
  }

  static bool _sameLines(List<Line> a, List<Line> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (identical(a[i], b[i])) continue;
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }

  void _record(List<Line> before, Pos cursorBefore) {
    _undo.add(
      _Change(_nextId++, before, List.of(_lines), cursorBefore, _cursor),
    );
    _redo.clear();
  }

  void _visualKey(String key) {
    if (_move(key)) return;
    switch (key) {
      case 'y':
        _yankSelection();
      case 'd':
        _deleteSelection();
      case 'v' || '<Esc>':
        _mode = Mode.normal;
    }
  }

  /// Sets the command line to [text], with the cursor at its end.
  void _setCmdline(String text) {
    _cmdline = text;
    _cmdPos = text.runes.length;
  }

  /// The command line before the cursor.
  String _cmdBefore() => String.fromCharCodes(_cmdline.runes.take(_cmdPos));

  /// Inserts [text] at the cursor of the command line.
  void _insertCmd(String text) {
    final runes = _cmdline.runes.toList();
    _cmdline = String.fromCharCodes([
      ...runes.take(_cmdPos),
      ...text.runes,
      ...runes.skip(_cmdPos),
    ]);
    _cmdPos += text.runes.length;
    _historyIndex = _historyEntries.length;
  }

  void _commandKey(String key) {
    switch (key) {
      case '<Esc>':
        _mode = Mode.normal;
        _setCmdline('');
      case '<CR>':
        final cmd = _cmdline;
        _mode = Mode.normal;
        _setCmdline('');
        if (_cmdPrefix == '/') {
          if (cmd.isNotEmpty) _history.add('/$cmd');
          _startSearch(cmd);
        } else {
          // Of `:` commands, only those on every line (`:%s/...`) are kept.
          if (cmd.startsWith('%')) _history.add(':$cmd');
          _execute(cmd);
        }
      case '<BS>':
        if (_cmdline.isEmpty) {
          _mode = Mode.normal;
        } else if (_cmdPos > 0) {
          // Deletes the character before the cursor; nothing at the start,
          // as in vim.
          final runes = _cmdline.runes.toList()..removeAt(_cmdPos - 1);
          _cmdline = String.fromCharCodes(runes);
          _cmdPos--;
          _historyIndex = _historyEntries.length;
        }
      case '<Left>':
        if (_cmdPos > 0) _cmdPos--;
      case '<Right>':
        if (_cmdPos < _cmdline.runes.length) _cmdPos++;
      case '<Up>':
        _browseHistory(older: true);
      case '<Down>':
        _browseHistory(older: false);
      default:
        if (key.runes.length == 1) _insertCmd(key);
    }
  }

  /// `<Up>` / `<Down>` on the command line: shows the previous or next
  /// history entry for this prompt that starts with what was typed, as vim
  /// does. Going past the newest one shows what was typed again.
  void _browseHistory({required bool older}) {
    final entries = _historyEntries;
    if (_historyIndex == entries.length) _historyTyped = _cmdline;
    final start = '$_cmdPrefix$_historyTyped';
    var i = _historyIndex;
    while (true) {
      i += older ? -1 : 1;
      if (i < 0) return;
      if (i >= entries.length) {
        _historyIndex = entries.length;
        _setCmdline(_historyTyped);
        return;
      }
      if (entries[i].startsWith(start)) break;
    }
    _historyIndex = i;
    _setCmdline(entries[i].substring(_cmdPrefix.length));
  }

  void _execute(String cmd) {
    // Not trimmed at the end: trailing spaces may be part of a replacement.
    final Substitute? sub;
    try {
      sub = Substitute.parse(cmd.trimLeft());
    } on FormatException catch (e) {
      _error(e.message);
      return;
    }
    if (sub != null) {
      _substitute(sub);
      return;
    }
    switch (cmd.trim()) {
      case '':
        break;
      case 'w':
        _write(force: false);
      case 'w!':
        _write(force: true);
      case 'q':
        if (modified) {
          _error('E37: No write since last change (add ! to override)');
        } else {
          quit = true;
        }
      case 'q!':
        quit = true;
      case 'wq':
        if (_write(force: false)) quit = true;
      // :noh, :nohl, ... :nohlsearch
      case final c when c.length >= 3 && 'nohlsearch'.startsWith(c):
        _hlsearch = false;
      default:
        _error('E492: Not an editor command: ${cmd.trim()}');
    }
  }

  /// `:s`: replaces matches in the lines of its range (the cursor line by
  /// default) as one change, and leaves the cursor on the last changed line,
  /// as vim does. Its pattern becomes the last search pattern.
  void _substitute(Substitute sub) {
    final range = _rows(sub.range);
    if (range == null) return;
    final (first, last) = range;
    final RegExp regex;
    if (sub.pattern.isEmpty) {
      final previous = _lastSearch;
      if (previous == null) {
        _error('E35: No previous regular expression');
        return;
      }
      regex = RegExp(
        previous.pattern,
        unicode: true,
        caseSensitive: !sub.ignoreCase && previous.isCaseSensitive,
      );
    } else {
      try {
        regex = RegExp(
          sub.pattern,
          unicode: true,
          caseSensitive: !sub.ignoreCase,
        );
      } on FormatException catch (e) {
        _error('E383: Invalid search string: ${e.message}');
        return;
      }
    }
    _lastSearch = regex;
    _hlsearch = true;

    final before = List.of(_lines);
    final cursorBefore = _cursor;
    if (!sub.global) {
      _confirm = _Confirm(sub, regex, first, last, before, cursorBefore);
      _mode = Mode.confirm;
      _message = '';
      _confirmNext();
      return;
    }
    var count = 0;
    var lines = 0;
    var lastRow = -1;
    for (var r = first; r <= last; r++) {
      final text = String.fromCharCodes(_lines[r]);
      var n = 0;
      final out = text.replaceAllMapped(regex, (m) {
        n++;
        return sub.expand(m);
      });
      if (n == 0) continue;
      count += n;
      lines++;
      lastRow = r;
      if (out != text) _lines[r] = out.runes.toList();
    }
    if (count == 0) {
      _error('E486: Pattern not found: ${regex.pattern}');
      return;
    }
    _setCursor(Pos(lastRow, _firstNonBlank(_lines[lastRow])));
    if (!_sameLines(before, _lines)) _record(before, cursorBefore);
    _reportSubstitutions(count, lines);
  }

  void _reportSubstitutions(int count, int lines) {
    if (count > 2) {
      _info('$count substitutions on $lines line${lines == 1 ? '' : 's'}');
    }
  }

  /// Moves to the next match of the `:s` being confirmed, or finishes it
  /// when there is none.
  void _confirmNext() {
    final c = _confirm!;
    while (c.row <= c.lastRow) {
      final text = String.fromCharCodes(_lines[c.row]);
      if (c.from <= text.length) {
        final m = c.regex.allMatches(text, c.from).firstOrNull;
        if (m != null) {
          c
            ..match = m
            ..found = true;
          _setCursor(Pos(c.row, _colAt(_lines[c.row], m.start)));
          return;
        }
      }
      c.row++;
      c.from = 0;
    }
    _finishConfirm();
  }

  /// `y` or Enter replaces the match, `n` skips it, Esc stops.
  void _confirmKey(String key) {
    final c = _confirm!;
    final m = c.match!;
    final text = m.input;
    switch (key) {
      case 'y' || '<CR>':
        final replacement = c.sub.expand(m);
        final out =
            text.substring(0, m.start) + replacement + text.substring(m.end);
        _lines[c.row] = out.runes.toList();
        c.count++;
        c.changedRows.add(c.row);
        c.lastChanged = c.row;
        // Not inside the replacement.
        c.from = _nextFrom(out, m.start + replacement.length, m);
      case 'n':
        c.from = _nextFrom(text, m.end, m);
      case '<Esc>':
        _finishConfirm();
        return;
      default:
        return;
    }
    _confirmNext();
  }

  /// Where to look for the match after [m], which ends at [end] in [text]:
  /// one character further after an empty match, so it is not found again.
  static int _nextFrom(String text, int end, Match m) {
    if (m.end > m.start) return end;
    if (end >= text.length) return text.length + 1;
    final unit = text.codeUnitAt(end);
    return end + (unit >= 0xd800 && unit < 0xdc00 ? 2 : 1);
  }

  String _confirmPrompt() {
    final c = _confirm;
    final m = c?.match;
    if (c == null || m == null) return '';
    return 'replace with ${c.sub.expand(m)}? (Y/n)';
  }

  /// Ends the `:s` being confirmed: what was replaced becomes one change.
  void _finishConfirm() {
    final c = _confirm!;
    _confirm = null;
    _mode = Mode.normal;
    if (!c.found) {
      _setCursor(c.cursorBefore);
      _error('E486: Pattern not found: ${c.regex.pattern}');
      return;
    }
    if (c.count == 0) {
      _setCursor(c.cursorBefore);
      return;
    }
    _setCursor(Pos(c.lastChanged, _firstNonBlank(_lines[c.lastChanged])));
    if (!_sameLines(c.before, _lines)) _record(c.before, c.cursorBefore);
    _reportSubstitutions(c.count, c.changedRows.length);
  }

  /// Rows of a command range (see [Substitute.range]), or null after showing
  /// an error.
  (int, int)? _rows((String, String?)? range) {
    if (range == null) return (_row, _row);
    final (a, b) = range;
    if (a == '%') return (0, _lines.length - 1);
    int row(String address) => switch (address) {
      '.' => _row,
      r'$' => _lines.length - 1,
      // Line 0 means line 1 here, as in vim.
      _ => max(1, int.parse(address)) - 1,
    };
    final first = row(a);
    final last = b == null ? first : row(b);
    if (first >= _lines.length || last >= _lines.length) {
      _error('E16: Invalid range');
      return null;
    }
    if (first > last) {
      _error('E493: Backwards range given');
      return null;
    }
    return (first, last);
  }

  /// `/` followed by Enter: searches for [text], a Dart (JavaScript-style)
  /// regular expression. An empty [text] repeats the last search, as in vim.
  void _startSearch(String text) {
    if (text.isNotEmpty) {
      try {
        _lastSearch = RegExp(text, unicode: true);
      } on FormatException catch (e) {
        _error('E383: Invalid search string: ${e.message}');
        return;
      }
    }
    _searchAgain(forward: true);
  }

  /// Moves to the next match of the last search, wrapping around the end of
  /// the buffer.
  void _searchAgain({required bool forward}) {
    final pattern = _lastSearch;
    if (pattern == null) {
      _error('E35: No previous regular expression');
      return;
    }
    _hlsearch = true;
    final shown = '${forward ? '/' : '?'}${pattern.pattern}';
    final n = _lines.length;
    // The last step comes back to the cursor line, for a match on the other
    // side of the cursor.
    for (var i = 0; i <= n; i++) {
      final r = forward ? _row + i : _row - i;
      final line = _lines[r % n];
      final col = forward
          ? _indexOf(line, pattern, i == 0 ? _col + 1 : 0)
          : _lastIndexOf(line, pattern, i == 0 ? _col - 1 : line.length);
      if (col < 0) continue;
      _setCursor(Pos(r % n, col));
      if (r >= n) {
        _info('search hit BOTTOM, continuing at TOP');
      } else if (r < 0) {
        _info('search hit TOP, continuing at BOTTOM');
      } else {
        _info(shown);
      }
      return;
    }
    _error('E486: Pattern not found: ${pattern.pattern}');
  }

  /// First column at or after [from] where [pattern] matches in [line], or
  /// -1. The text before [from] still counts for `\b` and lookbehind.
  static int _indexOf(Line line, RegExp pattern, int from) {
    if (from > line.length) return -1;
    final text = String.fromCharCodes(line);
    final m = pattern.allMatches(text, _utf16Offset(line, from)).firstOrNull;
    return m == null ? -1 : _colAt(line, m.start);
  }

  /// Last column at or before [before] where [pattern] matches in [line], or
  /// -1. Overlapping matches count, as in vim.
  static int _lastIndexOf(Line line, RegExp pattern, int before) {
    final text = String.fromCharCodes(line);
    var found = -1;
    var col = 0;
    while (col <= min(before, line.length)) {
      final m = pattern.allMatches(text, _utf16Offset(line, col)).firstOrNull;
      if (m == null) break;
      final c = _colAt(line, m.start);
      if (c > before) break;
      found = c;
      col = c + 1;
    }
    return found;
  }

  /// UTF-16 offset of column [col] in [line].
  static int _utf16Offset(Line line, int col) {
    var offset = 0;
    for (var i = 0; i < col; i++) {
      offset += line[i] > 0xffff ? 2 : 1;
    }
    return offset;
  }

  /// Column of UTF-16 offset [offset] in [line].
  static int _colAt(Line line, int offset) {
    var col = 0;
    for (var o = 0; o < offset; col++) {
      o += line[col] > 0xffff ? 2 : 1;
    }
    return col;
  }

  bool _move(String key) {
    switch (key) {
      case '<Left>':
        if (_col > 0) _col--;
        _wantDisp = dispCol(_lines[_row], _col);
      case '<Right>':
        if (_col < _maxCol(_row)) _col++;
        _wantDisp = dispCol(_lines[_row], _col);
      case '<Down>':
        if (_row < _lines.length - 1) {
          _row++;
          _col = _colAtWant();
        }
      case '<Up>':
        if (_row > 0) {
          _row--;
          _col = _colAtWant();
        }
      case '<PageDown>':
        // Like vim: keep two lines of context, cursor to the top line.
        if (_top < _lines.length - 1) {
          _top = min(_top + max(1, _textRows - 2), _lines.length - 1);
          _row = _top;
          _col = _colAtWant();
        }
      case '<PageUp>':
        // Cursor goes to the bottom line of the new view.
        if (_top > 0) {
          _top = max(0, _top - max(1, _textRows - 2));
          _row = min(_top + _textRows - 1, _lines.length - 1);
          _col = _colAtWant();
        }
      default:
        return false;
    }
    return true;
  }

  /// Last cursor column; in insert mode the cursor may sit after the end.
  int _maxCol(int row) => _mode == Mode.insert
      ? _lines[row].length
      : max(0, _lines[row].length - 1);

  int _colAtWant() {
    final line = _lines[_row];
    if (_mode == Mode.insert && _wantDisp >= dispCol(line, line.length)) {
      return line.length;
    }
    return colAtDisp(line, _wantDisp);
  }

  void _setCursor(Pos pos) {
    _row = pos.row.clamp(0, _lines.length - 1);
    _col = pos.col.clamp(0, _maxCol(_row));
    _wantDisp = dispCol(_lines[_row], _col);
  }

  (Pos, Pos) _selection() {
    final c = _cursor;
    return _anchor.compareTo(c) <= 0 ? (_anchor, c) : (c, _anchor);
  }

  void _yankLine() {
    _setRegister(_Register([_lines[_row]], linewise: true));
  }

  void _yankSelection() {
    final (s, e) = _selection();
    _setRegister(_Register(_selectedText(s, e), linewise: false));
    _mode = Mode.normal;
    _setCursor(s);
    final n = e.row - s.row + 1;
    if (n > 2) _info('$n lines yanked');
  }

  void _deleteSelection() {
    final (s, e) = _selection();
    _setRegister(_Register(_selectedText(s, e), linewise: false));
    final before = List.of(_lines);
    final cursorBefore = _cursor;
    final head = _lines[s.row].sublist(0, min(s.col, _lines[s.row].length));
    final last = _lines[e.row];
    if (last.isEmpty && e.row + 1 < _lines.length) {
      // The selection ends on a line break: join with the following line.
      _lines.replaceRange(s.row, e.row + 2, [
        [...head, ..._lines[e.row + 1]],
      ]);
    } else {
      final tail = last.isEmpty ? <int>[] : last.sublist(e.col + 1);
      _lines.replaceRange(s.row, e.row + 1, [
        [...head, ...tail],
      ]);
    }
    _mode = Mode.normal;
    _setCursor(s);
    _record(before, cursorBefore);
    final n = before.length - _lines.length;
    if (n > 2) _info('$n fewer lines');
  }

  void _deleteLine() {
    _setRegister(_Register([_lines[_row]], linewise: true));
    final before = List.of(_lines);
    final cursorBefore = _cursor;
    _lines.removeAt(_row);
    if (_lines.isEmpty) {
      _lines.add(<int>[]);
      _info('--No lines in buffer--');
    }
    final row = min(_row, _lines.length - 1);
    _setCursor(Pos(row, _firstNonBlank(_lines[row])));
    _record(before, cursorBefore);
  }

  static int _firstNonBlank(Line line) {
    var col = 0;
    while (col < line.length && (line[col] == 0x20 || line[col] == 0x09)) {
      col++;
    }
    return col;
  }

  /// Text from [s] to [e] inclusive, as charwise register parts.
  List<Line> _selectedText(Pos s, Pos e) {
    final parts = <Line>[];
    if (s.row == e.row) {
      final line = _lines[s.row];
      if (line.isEmpty) {
        // Only the line break is selected.
        parts
          ..add(<int>[])
          ..add(<int>[]);
      } else {
        parts.add(line.sublist(s.col, min(e.col + 1, line.length)));
      }
    } else {
      final first = _lines[s.row];
      parts.add(first.sublist(min(s.col, first.length)));
      for (var r = s.row + 1; r < e.row; r++) {
        parts.add(_lines[r]);
      }
      final last = _lines[e.row];
      parts.add(last.sublist(0, min(e.col + 1, last.length)));
      if (last.isEmpty) parts.add(<int>[]);
    }
    return parts;
  }

  void _paste() {
    final reg = _register;
    if (reg == null) {
      _error('E353: Nothing in register "');
      return;
    }
    final before = List.of(_lines);
    final cursorBefore = _cursor;
    if (reg.linewise) {
      _lines.insertAll(_row + 1, reg.parts);
      _row++;
      _setCursor(Pos(_row, _firstNonBlank(_lines[_row])));
    } else {
      final at = _lines[_row].isEmpty ? 0 : _col + 1;
      final end = _insertText(Pos(_row, at), reg.parts);
      _setCursor(
        reg.parts.length == 1 ? Pos(_row, end.col - 1) : Pos(_row, at),
      );
    }
    _record(before, cursorBefore);
  }

  /// Inserts [parts] (text separated by newlines) at [at] and returns the
  /// position right after the inserted text.
  Pos _insertText(Pos at, List<Line> parts) {
    final line = _lines[at.row];
    final head = line.sublist(0, at.col);
    final tail = line.sublist(at.col);
    if (parts.length == 1) {
      _lines[at.row] = [...head, ...parts.first, ...tail];
      return Pos(at.row, at.col + parts.first.length);
    }
    _lines.replaceRange(at.row, at.row + 1, [
      [...head, ...parts.first],
      ...parts.sublist(1, parts.length - 1),
      [...parts.last, ...tail],
    ]);
    return Pos(at.row + parts.length - 1, parts.last.length);
  }

  /// Text pasted from the terminal (bracketed paste): typed in insert mode,
  /// inserted before the cursor in normal mode, as vim does.
  void _pasteText(String text) {
    final parts = [
      for (final l
          in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'))
        l.runes.toList(),
    ];
    switch (_mode) {
      case Mode.insert:
        _setCursor(_insertText(_cursor, parts));
      case Mode.normal:
        _pendingOp = null;
        final before = List.of(_lines);
        final cursorBefore = _cursor;
        final end = _insertText(_cursor, parts);
        _setCursor(Pos(end.row, end.col - 1));
        _record(before, cursorBefore);
      case Mode.command:
        _insertCmd(String.fromCharCodes(parts.first));
      case Mode.visual || Mode.confirm:
        break;
    }
  }

  /// Sends a request for the shared register; [probeSharedRegister] at start
  /// tells whether there is one.
  void probeSharedRegister() => _requestRegister();

  void _requestRegister() {
    registerRequest++;
    send?.call('\x1b]7520;get\x07');
  }

  /// `p`: pastes the shared register if the terminal has one, as it holds
  /// the latest yank of any uim; otherwise this uim's own register.
  void _requestPaste() {
    if (send == null || sharedRegister == false) {
      _paste();
      return;
    }
    _waitingForRegister = true;
    _requestRegister();
  }

  void _receiveRegister(String reply) {
    sharedRegister = true;
    final register = _decodeRegister(reply);
    if (register != null) _register = register;
    if (_waitingForRegister) _finishPaste();
  }

  /// Called when request [request] got no reply in time.
  void registerTimedOut(int request) {
    if (request != registerRequest) return;
    sharedRegister ??= false;
    if (_waitingForRegister) _finishPaste();
  }

  void _finishPaste() {
    _waitingForRegister = false;
    _paste();
    while (_queuedKeys.isNotEmpty && !_waitingForRegister && !quit) {
      handleKey(_queuedKeys.removeAt(0));
    }
  }

  /// Sets the register and, unless the terminal has no shared register,
  /// shares it.
  void _setRegister(_Register register) {
    _register = register;
    final send = this.send;
    if (send == null || sharedRegister == false) return;
    final lines = register.parts.map(String.fromCharCodes);
    final text = register.linewise
        ? lines.map((l) => '$l\n').join()
        : lines.join('\n');
    send(
      '\x1b]7520;set;${register.linewise ? 'line' : 'char'};'
      '${base64Encode(utf8.encode(text))}\x07',
    );
  }

  /// Decodes a reply (`line;Base64`, `char;Base64` or `empty`); null if it is
  /// empty or malformed.
  static _Register? _decodeRegister(String reply) {
    final semicolon = reply.indexOf(';');
    if (semicolon < 0) return null;
    final kind = reply.substring(0, semicolon);
    if (kind != 'line' && kind != 'char') return null;
    final String text;
    try {
      text = utf8.decode(
        base64Decode(reply.substring(semicolon + 1)),
        allowMalformed: true,
      );
    } on FormatException {
      return null;
    }
    final linewise = kind == 'line';
    final body = linewise && text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    return _Register([
      for (final l in body.split('\n')) l.runes.toList(),
    ], linewise: linewise);
  }

  void _undoChange() {
    if (_undo.isEmpty) {
      _info('Already at oldest change');
      return;
    }
    final c = _undo.removeLast();
    _redo.add(c);
    _lines = List.of(c.before);
    _setCursor(c.cursorBefore);
  }

  void _redoChange() {
    if (_redo.isEmpty) {
      _info('Already at newest change');
      return;
    }
    final c = _redo.removeLast();
    _undo.add(c);
    _lines = List.of(c.after);
    _setCursor(c.cursorAfter);
  }

  bool _write({required bool force}) {
    final p = path;
    if (p == null) {
      _error('E32: No file name');
      return false;
    }
    final file = File(p);
    final exists = file.existsSync();
    final empty = _loadedEmpty && _lines.length == 1 && _lines.first.isEmpty;
    final eol = _lineEnding.text;
    final data = encodeText(
      empty ? '' : '${_lines.map(String.fromCharCodes).join(eol)}$eol',
      _encoding,
    );
    if (data == null) {
      _error('E513: Write error, conversion failed (${_encoding.label})');
      return false;
    }
    try {
      if (exists && !_isWritable(file)) {
        if (!force) {
          _error("E45: 'readonly' option is set (add ! to override)");
          return false;
        }
        _replaceFile(file, data);
      } else {
        file.writeAsBytesSync(data, flush: true);
      }
    } on FileSystemException {
      _error("E212: Can't open file for writing");
      return false;
    }
    _savedId = _currentId;
    final lineCount = empty ? 0 : _lines.length;
    _info(
      '"$p" ${exists ? '' : '[New] '}${lineCount}L, ${data.length}B written',
    );
    return true;
  }

  static bool _isWritable(File file) {
    try {
      file.openSync(mode: FileMode.append).closeSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Writes a file we have no write permission for by creating a new file
  /// next to it and renaming it over the original, keeping its mode.
  static void _replaceFile(File file, List<int> data) {
    final target = file.resolveSymbolicLinksSync();
    final mode = File(target).statSync().mode & 0xfff;
    final tmp = File('$target.uim-tmp');
    tmp.writeAsBytesSync(data, flush: true);
    Process.runSync('chmod', [mode.toRadixString(8), tmp.path]);
    tmp.renameSync(target);
  }

  void _info(String message) {
    _message = message;
    _messageIsError = false;
  }

  void _error(String message) {
    _message = message;
    _messageIsError = true;
  }

  /// Returns the escape sequences that draw the whole screen.
  String render(int rows, int cols) {
    final textRows = _textRows = max(1, rows - 1);
    if (_row < _top) _top = _row;
    if (_row >= _top + textRows) _top = _row - textRows + 1;

    final line = _lines[_row];
    final curDisp = dispCol(line, _col);
    final curWidth = _col < line.length
        ? max(1, cellWidth(line[_col], curDisp))
        : 1;
    if (curDisp < _left) _left = curDisp;
    if (curDisp + curWidth > _left + cols) _left = curDisp + curWidth - cols;

    final sel = _mode == Mode.visual ? _selection() : null;
    final styles = _styles(_top, min(_top + textRows, _lines.length));
    final sb = StringBuffer('\x1b[?25l\x1b[H');
    for (var i = 0; i < textRows; i++) {
      final r = _top + i;
      if (r < _lines.length) {
        _renderLine(sb, r, cols, sel, styles?[i], _matches(r));
      } else {
        sb.write('\x1b[94m~\x1b[0m');
      }
      sb.write('\x1b[K\r\n');
    }

    _renderStatus(sb, cols);

    // On the command line, the status line shows the cursor as a reversed
    // character, and the terminal's cursor stays hidden so that it does not
    // reverse it back.
    if (_mode != Mode.command) {
      sb.write('\x1b[${_row - _top + 1};${curDisp - _left + 1}H\x1b[?25h');
    }
    return sb.toString();
  }

  /// The bottom line: black on white, with the mode, command line or message
  /// on the left and the file's encoding and line ending on the right.
  void _renderStatus(StringBuffer sb, int cols) {
    const bar = '\x1b[0;30;107m';
    final right = '${_encoding.label} / ${_lineEnding.label}';
    final rightWidth = stringWidth(right);
    // Keep one column between the two, and drop the right part if it does
    // not fit.
    final showRight = rightWidth + 2 <= cols;
    final leftCols = showRight ? cols - rightWidth - 1 : cols;
    final (left, style) = switch (_mode) {
      Mode.command => ('$_cmdPrefix$_cmdline', ''),
      Mode.insert => ('-- INSERT --', '\x1b[1m'),
      Mode.visual => ('-- VISUAL --', '\x1b[1m'),
      Mode.confirm => (_confirmPrompt(), ''),
      Mode.normal => (_message, _messageIsError ? '\x1b[97;41m' : ''),
    };
    sb
      ..write(bar)
      ..write(style);
    final used = _mode == Mode.command
        ? _writeCmdline(sb, leftCols)
        : _writeFitted(sb, left, leftCols);
    sb
      ..write(bar)
      ..write(' ' * (leftCols - used));
    if (showRight) sb.write(' $right');
    sb.write('\x1b[0m');
  }

  /// Writes as much of [text] as fits in [cols] and returns its width.
  static int _writeFitted(StringBuffer sb, String text, int cols) {
    final fitted = fitWidth(text, cols);
    sb.write(fitted);
    return stringWidth(fitted);
  }

  /// Writes the command line in [cols] with the character at the cursor
  /// reversed (a space after the end), and returns its width. When it does
  /// not fit, its start is cut so that the cursor stays in view.
  int _writeCmdline(StringBuffer sb, int cols) {
    final runes = _cmdline.runes.toList();
    final at = _cmdPos < runes.length
        ? String.fromCharCode(runes[_cmdPos])
        : ' ';
    final atWidth = stringWidth(at);
    final beforeRunes = '$_cmdPrefix${_cmdBefore()}'.runes.toList();
    var skip = 0;
    while (skip < beforeRunes.length &&
        stringWidth(String.fromCharCodes(beforeRunes.skip(skip))) + atWidth >
            cols) {
      skip++;
    }
    final before = String.fromCharCodes(beforeRunes.skip(skip));
    var used = _writeFitted(sb, before, cols);
    if (used + atWidth > cols) return used;
    sb.write('\x1b[7m');
    used += _writeFitted(sb, at, cols - used);
    sb.write('\x1b[27m');
    final after = String.fromCharCodes(runes.skip(_cmdPos + 1));
    return used + _writeFitted(sb, after, cols - used);
  }

  List<List<String?>>? _styles(int first, int last) {
    final highlighter = _highlighter;
    if (highlighter == null) return null;
    if (!_sameIdentity(_highlighted, _lines)) {
      highlighter.update(_lines);
      _highlighted = List.of(_lines);
    }
    return highlighter.styles(_lines, first, last);
  }

  static bool _sameIdentity(List<Line> a, List<Line> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// Column ranges (start inclusive, end exclusive) of the search matches in
  /// row [r], left to right; empty when search highlighting is off. Matches
  /// do not overlap, and empty ones are left out as they have nothing to
  /// color.
  List<(int, int)> _matches(int r) {
    final pattern = _lastSearch;
    if (!_hlsearch || pattern == null) return const [];
    final line = _lines[r];
    return [
      for (final m in pattern.allMatches(String.fromCharCodes(line)))
        if (m.end > m.start) (_colAt(line, m.start), _colAt(line, m.end)),
    ];
  }

  void _renderLine(
    StringBuffer sb,
    int r,
    int cols,
    (Pos, Pos)? sel,
    List<String?>? styles,
    List<(int, int)> matches,
  ) {
    bool selected(int c) {
      if (sel == null) return false;
      final p = Pos(r, c);
      return sel.$1.compareTo(p) <= 0 && p.compareTo(sel.$2) <= 0;
    }

    final matchStyle = _colors.searchStyle(current: false);
    final currentStyle = _colors.searchStyle(current: true);
    var m = 0;

    /// Search style of column [c] (columns are asked for in order), or null.
    String? searchStyle(int c) {
      while (m < matches.length && matches[m].$2 <= c) {
        m++;
      }
      if (m == matches.length || c < matches[m].$1) return null;
      final (start, end) = matches[m];
      final current = r == _row && start <= _col && _col < end;
      return current ? currentStyle : matchStyle;
    }

    final line = _lines[r];
    final right = _left + cols;
    // Current attributes; `null` style is the default color.
    var reversed = false;
    String? style;
    var d = 0;
    for (var i = 0; i < line.length; i++) {
      final w = cellWidth(line[i], d);
      final start = d;
      d += w;
      if (d <= _left && w > 0) continue;
      if (start >= right) break;
      final rev = selected(i);
      // The search colors go after the syntax color, so they win.
      final s = [
        styles?[i],
        searchStyle(i),
      ].where((s) => s != null && s.isNotEmpty).join(';');
      if (rev != reversed || (s.isEmpty ? null : s) != style) {
        sb.write('\x1b[0m');
        if (rev) sb.write('\x1b[7m');
        if (s.isNotEmpty) sb.write('\x1b[${s}m');
        reversed = rev;
        style = s.isEmpty ? null : s;
      }
      if (start < _left || d > right) {
        // Partially visible wide character or tab.
        sb.write(' ' * (min(d, right) - max(start, _left)));
      } else {
        sb.write(glyph(line[i], w));
      }
    }
    if (reversed || style != null) sb.write('\x1b[0m');
    if (line.isEmpty && _left == 0 && selected(0)) sb.write('\x1b[7m \x1b[0m');
  }
}
