import 'dart:io';
import 'dart:math';

/// Command-line history in ~/.local/state/uim/history, shared by every uim:
/// one entry per line, each starting with its prompt (`/` or `:`), oldest
/// first.
class History {
  History(this.path);

  /// The history of the user running uim; it is not kept without `$HOME`.
  factory History.forUser() {
    final home = Platform.environment['HOME'];
    return History(home == null ? null : '$home/.local/state/uim/history');
  }

  static const limit = 100;

  final String? path;

  /// The entries, oldest first; empty if the file cannot be read.
  List<String> read() {
    final p = path;
    if (p == null) return [];
    try {
      return File(p).readAsLinesSync().where((l) => l.isNotEmpty).toList();
    } on Exception {
      return [];
    }
  }

  /// Adds [entry] as the newest one, removing an older copy of it and the
  /// oldest entries beyond [limit]. The file is read again first, so entries
  /// other uims added meanwhile are kept, and replaced by a rename, so it is
  /// never left half written. History is not essential, so failures are
  /// ignored.
  void add(String entry) {
    final p = path;
    if (p == null) return;
    final entries = read()
      ..remove(entry)
      ..add(entry);
    final kept = entries.sublist(max(0, entries.length - limit));
    try {
      File(p).parent.createSync(recursive: true);
      final tmp = File('$p.$pid.tmp');
      tmp.writeAsStringSync(kept.map((e) => '$e\n').join(), flush: true);
      tmp.renameSync(p);
    } on FileSystemException {
      // Ignored, see above.
    }
  }
}
