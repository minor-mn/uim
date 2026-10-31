import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'colors.dart';
import 'src/languages.dart';
import 'src/tree_sitter_ffi.dart';

/// A test on the text of one capture, such as `(#match? @name "^[A-Z]")`.
class _Predicate {
  _Predicate(this.captureId, this.test);

  final int captureId;
  final bool Function(String text) test;
}

/// Syntax highlighting with tree-sitter.
class Highlighter {
  Highlighter._(
    Pointer<TSLanguage> language,
    String querySource,
    Colors colors,
  ) {
    _parser = ts_parser_new();
    ts_parser_set_language(_parser, language);
    _query = _newQuery(language, querySource);
    _cursor = ts_query_cursor_new();

    final length = calloc<Uint32>();
    try {
      for (var i = 0; i < ts_query_capture_count(_query); i++) {
        final name = ts_query_capture_name_for_id(_query, i, length);
        _captureStyles.add(colors.styleFor(_string(name, length.value)));
      }
      for (var i = 0; i < ts_query_pattern_count(_query); i++) {
        _predicates.add(_parsePredicates(i));
      }
    } finally {
      calloc.free(length);
    }
  }

  /// Returns a highlighter for the language of [path], or null if there is
  /// none for it.
  static Highlighter? forPath(String? path, Colors colors) {
    final language = path == null ? null : languageForPath(path);
    if (language == null) return null;
    return Highlighter._(language.load(), language.highlights, colors);
  }

  late final Pointer<TSParser> _parser;
  late final Pointer<TSQuery> _query;
  late final Pointer<TSQueryCursor> _cursor;
  final _captureStyles = <String?>[];
  final _predicates = <List<_Predicate>>[];

  /// Patterns with `(#is-not? local)`. uim does not track local variables,
  /// so these patterns never apply and more general ones take over.
  final _disabledPatterns = <int>{};

  Pointer<TSTree> _tree = nullptr;
  Uint8List _text = Uint8List(0);

  static Pointer<TSQuery> _newQuery(Pointer<TSLanguage> language, String s) {
    final bytes = utf8.encode(s);
    final source = malloc<Uint8>(bytes.length);
    final errorOffset = calloc<Uint32>();
    final errorType = calloc<Uint32>();
    try {
      source.asTypedList(bytes.length).setAll(0, bytes);
      final query = ts_query_new(
        language,
        source,
        bytes.length,
        errorOffset,
        errorType,
      );
      if (query == nullptr) {
        throw StateError(
          'invalid highlight query '
          '(error ${errorType.value} at byte ${errorOffset.value})',
        );
      }
      return query;
    } finally {
      malloc.free(source);
      calloc.free(errorOffset);
      calloc.free(errorType);
    }
  }

  static String _string(Pointer<Uint8> p, int length) =>
      utf8.decode(p.asTypedList(length));

  /// Collects the `#match?`, `#not-match?`, `#eq?`, `#not-eq?` and
  /// `#any-of?` predicates comparing a capture with strings, and notes
  /// `#is-not? local`. Other predicates are ignored.
  List<_Predicate> _parsePredicates(int pattern) {
    final count = calloc<Uint32>();
    final length = calloc<Uint32>();
    String value(TSQueryPredicateStep step) => _string(
      ts_query_string_value_for_id(_query, step.valueId, length),
      length.value,
    );
    bool isString(TSQueryPredicateStep step) => step.type == predicateString;
    try {
      final steps = ts_query_predicates_for_pattern(_query, pattern, count);
      final result = <_Predicate>[];
      var args = <TSQueryPredicateStep>[];
      for (var i = 0; i < count.value; i++) {
        final step = steps[i];
        if (step.type != predicateDone) {
          args.add(step);
          continue;
        }
        if (args.length == 2 &&
            args.every(isString) &&
            value(args[0]) == 'is-not?') {
          _disabledPatterns.add(pattern);
        } else if (args.length >= 3 &&
            isString(args[0]) &&
            args[1].type == predicateCapture &&
            args.skip(2).every(isString)) {
          final name = value(args[0]);
          final values = [for (final a in args.skip(2)) value(a)];
          bool Function(String)? test;
          switch (name) {
            case 'match?' || 'not-match?' when values.length == 1:
              final regExp = RegExp(values.single);
              final negate = name == 'not-match?';
              test = (text) => regExp.hasMatch(text) != negate;
            case 'eq?' when values.length == 1:
              test = (text) => text == values.single;
            case 'not-eq?' when values.length == 1:
              test = (text) => text != values.single;
            case 'any-of?':
              test = values.toSet().contains;
          }
          if (test != null) result.add(_Predicate(args[1].valueId, test));
        }
        args = [];
      }
      return result;
    } finally {
      calloc.free(count);
      calloc.free(length);
    }
  }

  /// Parses [lines] (code points per line), reusing the previous tree for the
  /// part that did not change.
  void update(List<List<int>> lines) {
    final text = utf8.encode('${lines.map(String.fromCharCodes).join('\n')}\n');
    if (_tree != nullptr) _editTree(text);
    final native = malloc<Uint8>(text.length);
    try {
      native.asTypedList(text.length).setAll(0, text);
      final tree = ts_parser_parse_string(_parser, _tree, native, text.length);
      if (_tree != nullptr) ts_tree_delete(_tree);
      _tree = tree;
      _text = text;
    } finally {
      malloc.free(native);
    }
  }

  /// Tells the old tree which byte range changed between [_text] and [text].
  void _editTree(Uint8List text) {
    final old = _text;
    final limit = old.length < text.length ? old.length : text.length;
    var prefix = 0;
    while (prefix < limit && old[prefix] == text[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < limit - prefix &&
        old[old.length - 1 - suffix] == text[text.length - 1 - suffix]) {
      suffix++;
    }
    if (prefix == old.length && prefix == text.length) return;
    // Keep the edit on UTF-8 character boundaries.
    while (prefix > 0 && old[prefix] & 0xc0 == 0x80) {
      prefix--;
    }
    while (suffix > 0 && old[old.length - suffix] & 0xc0 == 0x80) {
      suffix--;
    }
    final edit = calloc<TSInputEdit>();
    try {
      edit.ref
        ..startByte = prefix
        ..oldEndByte = old.length - suffix
        ..newEndByte = text.length - suffix;
      _setPoint(edit.ref.startPoint, old, prefix);
      _setPoint(edit.ref.oldEndPoint, old, old.length - suffix);
      _setPoint(edit.ref.newEndPoint, text, text.length - suffix);
      ts_tree_edit(_tree, edit);
    } finally {
      calloc.free(edit);
    }
  }

  static void _setPoint(TSPoint point, Uint8List text, int offset) {
    var row = 0;
    var lineStart = 0;
    for (var i = 0; i < offset; i++) {
      if (text[i] == 0x0a) {
        row++;
        lineStart = i + 1;
      }
    }
    point
      ..row = row
      ..column = offset - lineStart;
  }

  /// Returns the SGR style of every code point of rows [first] to [last]
  /// (exclusive) of [lines], which must be what was last passed to [update].
  List<List<String?>> styles(List<List<int>> lines, int first, int last) {
    final rows = [
      for (var r = first; r < last; r++)
        List<String?>.filled(lines[r].length, null),
    ];
    if (_tree == nullptr || first >= last) return rows;

    // Byte offset (within its line) of each code point, plus the line end.
    final offsets = [for (var r = first; r < last; r++) _byteOffsets(lines[r])];
    // Size and pattern of the capture that set each style: smaller nodes
    // win, and among equal nodes the later pattern wins.
    final sizes = [for (final row in rows) List.filled(row.length, -1)];
    final patterns = [for (final row in rows) List.filled(row.length, -1)];

    final start = Struct.create<TSPoint>()
      ..row = first
      ..column = 0;
    final end = Struct.create<TSPoint>()
      ..row = last
      ..column = 0;
    ts_query_cursor_set_point_range(_cursor, start, end);
    ts_query_cursor_exec(_cursor, _query, ts_tree_root_node(_tree));

    final match = calloc<TSQueryMatch>();
    final index = calloc<Uint32>();
    try {
      while (ts_query_cursor_next_capture(_cursor, match, index)) {
        final m = match.ref;
        if (!_predicatesHold(m)) {
          ts_query_cursor_remove_match(_cursor, m.id);
          continue;
        }
        final capture = m.captures[index.value];
        final style = _captureStyles[capture.index];
        if (style == null) continue;
        final node = capture.node;
        final size = ts_node_end_byte(node) - ts_node_start_byte(node);
        final from = ts_node_start_point(node);
        final to = ts_node_end_point(node);
        final firstRow = from.row < first ? first : from.row;
        final lastRow = to.row < last ? to.row : last - 1;
        for (var r = firstRow; r <= lastRow; r++) {
          final i = r - first;
          final startByte = r == from.row ? from.column : 0;
          final endByte = r == to.row ? to.column : 1 << 31;
          final lineOffsets = offsets[i];
          for (var c = 0; c < rows[i].length; c++) {
            final b = lineOffsets[c];
            if (b < startByte) continue;
            if (b >= endByte) break;
            final oldSize = sizes[i][c];
            if (oldSize < 0 ||
                size < oldSize ||
                (size == oldSize && m.patternIndex >= patterns[i][c])) {
              rows[i][c] = style;
              sizes[i][c] = size;
              patterns[i][c] = m.patternIndex;
            }
          }
        }
      }
    } finally {
      calloc.free(match);
      calloc.free(index);
    }
    return rows;
  }

  static List<int> _byteOffsets(List<int> line) {
    final offsets = List.filled(line.length, 0);
    var b = 0;
    for (var i = 0; i < line.length; i++) {
      offsets[i] = b;
      final r = line[i];
      b += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
    }
    return offsets;
  }

  bool _predicatesHold(TSQueryMatch m) {
    if (_disabledPatterns.contains(m.patternIndex)) return false;
    for (final p in _predicates[m.patternIndex]) {
      for (var i = 0; i < m.captureCount; i++) {
        final capture = m.captures[i];
        if (capture.index != p.captureId) continue;
        final node = capture.node;
        final text = utf8.decode(
          _text.sublist(ts_node_start_byte(node), ts_node_end_byte(node)),
          allowMalformed: true,
        );
        if (!p.test(text)) return false;
      }
    }
    return true;
  }
}
