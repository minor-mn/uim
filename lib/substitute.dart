/// A parsed `:s/pattern/replacement/flags` command, like vim's but with Dart
/// (JavaScript-style) regular expressions and `$1` in the replacement.
class Substitute {
  Substitute._(
    this.range,
    this.pattern,
    this.replacement, {
    required this.global,
    required this.ignoreCase,
  });

  /// `null` for the cursor line, `('%', null)` for every line, otherwise the
  /// first and optional last address (a line number, `.` or `$`).
  final (String, String?)? range;

  /// Empty to use the last search pattern, as in vim.
  final String pattern;
  final String replacement;

  /// `g`: replaces every match without asking. Without it, each match is
  /// asked about (`y` / Enter / `n`); this differs from vim, where that is
  /// the `c` flag and no `g` means only the first match of each line.
  final bool global;

  /// `i`: ignore case.
  final bool ignoreCase;

  static final _command = RegExp(
    r'^(?:(%)|(\d+|\.|\$)(?:,(\d+|\.|\$))?)?s(?:ubstitute)?([^\w\s\\"|])(.*)$',
  );

  /// Regex characters that keep their backslash when escaping the delimiter,
  /// so that they stay literal.
  static const _syntax = r'^$\.*+?()[]{}|/';

  /// Parses [cmd]; null if it is not a substitute command. Throws a
  /// [FormatException] for unknown flags.
  static Substitute? parse(String cmd) {
    final m = _command.firstMatch(cmd);
    if (m == null) return null;
    final delim = m[4]!;
    final [pattern, replacement, flags] = _split(m[5]!, delim);
    for (final f in flags.split('')) {
      if (f != 'g' && f != 'i') {
        throw FormatException('E488: Trailing characters: $flags');
      }
    }
    return Substitute._(
      m[1] != null ? ('%', null) : (m[2] == null ? null : (m[2]!, m[3])),
      pattern,
      replacement,
      global: flags.contains('g'),
      ignoreCase: flags.contains('i'),
    );
  }

  /// Splits [text] at unescaped [delim]s into the pattern, the replacement
  /// and the flags; missing parts are empty. A backslash escapes [delim]
  /// (and, in the replacement, a backslash).
  static List<String> _split(String text, String delim) {
    final parts = <String>[];
    var sb = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (parts.length < 2 && ch == '\\' && i + 1 < text.length) {
        final next = text[++i];
        if (parts.isEmpty) {
          // Pattern: keep escapes for the regex.
          if (next != delim || _syntax.contains(delim)) sb.write(ch);
          sb.write(next);
        } else {
          // Replacement.
          if (next != delim && next != '\\') sb.write(ch);
          sb.write(next);
        }
      } else if (parts.length < 2 && ch == delim) {
        parts.add(sb.toString());
        sb = StringBuffer();
      } else {
        sb.write(ch);
      }
    }
    parts.add(sb.toString());
    while (parts.length < 3) {
      parts.add('');
    }
    return parts;
  }

  /// The replacement for match [m], expanding `$1`-`$99`, `$&`, `$<name>`
  /// and `$$` as JavaScript does. Anything else is kept as it is.
  String expand(Match m) {
    final r = replacement;
    final sb = StringBuffer();
    int? digit(int i) {
      if (i >= r.length) return null;
      final c = r.codeUnitAt(i) - 0x30;
      return c >= 0 && c <= 9 ? c : null;
    }

    for (var i = 0; i < r.length; i++) {
      final ch = r[i];
      if (ch != r'$' || i + 1 >= r.length) {
        sb.write(ch);
        continue;
      }
      final next = r[i + 1];
      final d1 = digit(i + 1);
      if (next == r'$') {
        sb.write(r'$');
        i++;
      } else if (next == '&') {
        sb.write(m[0]);
        i++;
      } else if (d1 != null) {
        // Two digits if that group exists, as in JavaScript.
        final d2 = digit(i + 2);
        final two = d2 == null ? 0 : d1 * 10 + d2;
        if (two >= 1 && two <= m.groupCount) {
          sb.write(m[two] ?? '');
          i += 2;
        } else if (d1 >= 1 && d1 <= m.groupCount) {
          sb.write(m[d1] ?? '');
          i++;
        } else {
          sb.write(ch);
        }
      } else if (next == '<' && m is RegExpMatch) {
        final close = r.indexOf('>', i + 2);
        final name = close < 0 ? null : r.substring(i + 2, close);
        if (name != null && m.groupNames.contains(name)) {
          sb.write(m.namedGroup(name) ?? '');
          i = close;
        } else {
          sb.write(ch);
        }
      } else {
        sb.write(ch);
      }
    }
    return sb.toString();
  }
}
