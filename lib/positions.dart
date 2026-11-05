import 'dart:io';
import 'dart:math';

/// Cursor positions of files when uim last left them, in
/// ~/.local/state/uim/positions, shared by every uim: one file per line as
/// `row<TAB>col<TAB>path` (0-based row and column in code points, absolute
/// path), oldest first.
class Positions {
  Positions(this.path);

  /// The positions of the user running uim; they are not kept without `$HOME`.
  factory Positions.forUser() {
    final home = Platform.environment['HOME'];
    return Positions(home == null ? null : '$home/.local/state/uim/positions');
  }

  static const limit = 100;

  final String? path;

  /// Where [file] was left, or null if it is not known.
  (int, int)? get(String file) {
    final key = _key(file);
    if (key == null) return null;
    for (final (row, col, p) in _read().reversed) {
      if (p == key) return (row, col);
    }
    return null;
  }

  /// Records [row] and [col] as where [file] was left, as the newest entry,
  /// removing its older entry and the oldest ones beyond [limit]. The file is
  /// read again first, so entries other uims added meanwhile are kept, and
  /// replaced by a rename, so it is never left half written. Positions are
  /// not essential, so failures are ignored.
  void set(String file, int row, int col) {
    final p = path;
    final key = _key(file);
    if (p == null || key == null) return;
    final entries = _read()
      ..removeWhere((e) => e.$3 == key)
      ..add((row, col, key));
    final kept = entries.sublist(max(0, entries.length - limit));
    try {
      File(p).parent.createSync(recursive: true);
      final tmp = File('$p.$pid.tmp');
      tmp.writeAsStringSync(
        kept.map((e) => '${e.$1}\t${e.$2}\t${e.$3}\n').join(),
        flush: true,
      );
      tmp.renameSync(p);
    } on FileSystemException {
      // Ignored, see above.
    }
  }

  /// The entries, oldest first; empty if the file cannot be read.
  List<(int, int, String)> _read() {
    final p = path;
    if (p == null) return [];
    final List<String> lines;
    try {
      lines = File(p).readAsLinesSync();
    } on Exception {
      return [];
    }
    final entries = <(int, int, String)>[];
    for (final line in lines) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      final row = int.tryParse(parts[0]);
      final col = int.tryParse(parts[1]);
      if (row == null || col == null || row < 0 || col < 0) continue;
      entries.add((row, col, parts.sublist(2).join('\t')));
    }
    return entries;
  }

  /// [file] with symbolic links resolved, so every way of naming a file finds
  /// the same entry; null if it does not exist or its name cannot be kept on
  /// one line.
  static String? _key(String file) {
    if (file.contains('\n') || file.contains('\r')) return null;
    try {
      return File(file).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }
}
