import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'colors.dart';
import 'highlight.dart';
import 'terminal.dart';
import 'width.dart';

enum Mode { normal, insert, visual, command }

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

class Editor {
  Editor(String? path) : this._(path, Colors.load());

  Editor._(this.path, Colors colors)
    : _highlighter = Highlighter.forPath(path, colors) {
    _load();
    final error = colors.error;
    if (error != null) _error(error);
  }

  final String? path;
  final Highlighter? _highlighter;

  /// The lines last given to [_highlighter]. Lines are immutable, so
  /// comparing them by identity tells whether the buffer changed.
  List<Line> _highlighted = const [];

  List<Line> _lines = [<int>[]];

  /// Whether the file was empty (or did not exist) when loaded. A buffer of
  /// one empty line is then written as an empty file, as vim does.
  bool _loadedEmpty = true;

  int _row = 0;
  int _col = 0;

  /// Display column the cursor tries to keep when moving up and down.
  int _wantDisp = 0;

  Mode _mode = Mode.normal;
  Pos _anchor = const Pos(0, 0);
  String _cmdline = '';
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
    final text = utf8.decode(bytes, allowMalformed: true);
    final parts = text.split('\n');
    if (text.endsWith('\n')) parts.removeLast();
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
    }
  }

  /// Called on Ctrl-C.
  void interrupt() {
    _pendingOp = null;
    if (_mode == Mode.normal) {
      _info('Type  :q!  and press <Enter> to abandon all changes and exit uim');
    } else if (_mode == Mode.insert) {
      _leaveInsert();
    } else {
      _mode = Mode.normal;
      _cmdline = '';
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
      case ':':
        _mode = Mode.command;
        _cmdline = '';
        _message = '';
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

  void _commandKey(String key) {
    switch (key) {
      case '<Esc>':
        _mode = Mode.normal;
        _cmdline = '';
      case '<CR>':
        final cmd = _cmdline;
        _mode = Mode.normal;
        _cmdline = '';
        _execute(cmd);
      case '<BS>':
        if (_cmdline.isEmpty) {
          _mode = Mode.normal;
        } else {
          _cmdline = String.fromCharCodes(
            _cmdline.runes.toList()..removeLast(),
          );
        }
      default:
        if (key.runes.length == 1) _cmdline += key;
    }
  }

  void _execute(String cmd) {
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
      default:
        _error('E492: Not an editor command: ${cmd.trim()}');
    }
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
        _cmdline += String.fromCharCodes(parts.first);
      case Mode.visual:
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
    final data = empty
        ? <int>[]
        : utf8.encode('${_lines.map(String.fromCharCodes).join('\n')}\n');
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
        _renderLine(sb, r, cols, sel, styles?[i]);
      } else {
        sb.write('\x1b[94m~\x1b[0m');
      }
      sb.write('\x1b[K\r\n');
    }

    switch (_mode) {
      case Mode.command:
        sb.write(fitWidth(':$_cmdline', cols));
      case Mode.insert:
        sb.write('\x1b[1m${fitWidth('-- INSERT --', cols)}\x1b[0m');
      case Mode.visual:
        sb.write('\x1b[1m${fitWidth('-- VISUAL --', cols)}\x1b[0m');
      case Mode.normal:
        final text = fitWidth(_message, cols - 1);
        sb.write(_messageIsError ? '\x1b[97;41m$text\x1b[0m' : text);
    }
    sb.write('\x1b[K');

    final (y, x) = _mode == Mode.command
        ? (rows, min(cols, stringWidth(':$_cmdline') + 1))
        : (_row - _top + 1, curDisp - _left + 1);
    sb.write('\x1b[$y;${x}H\x1b[?25h');
    return sb.toString();
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

  void _renderLine(
    StringBuffer sb,
    int r,
    int cols,
    (Pos, Pos)? sel,
    List<String?>? styles,
  ) {
    bool selected(int c) {
      if (sel == null) return false;
      final p = Pos(r, c);
      return sel.$1.compareTo(p) <= 0 && p.compareTo(sel.$2) <= 0;
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
      final s = styles?[i] == '' ? null : styles?[i];
      if (rev != reversed || s != style) {
        sb.write('\x1b[0m');
        if (rev) sb.write('\x1b[7m');
        if (s != null) sb.write('\x1b[${s}m');
        reversed = rev;
        style = s;
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
