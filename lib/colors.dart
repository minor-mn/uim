import 'dart:io';

import 'package:json5/json5.dart';

import 'src/colors.g.dart';

/// Captures that are not about highlighting (Neovim spell checking).
const _ignored = {'spell', 'nospell'};

/// SGR parameters for capture names: the defaults in config/color.json5,
/// overridden key by key by ~/.config/uim/color.json5.
class Colors {
  Colors._(this._styles, this.error);

  static Colors load() {
    final styles = _parse(defaultColors);
    final home = Platform.environment['HOME'];
    if (home == null) return Colors._(styles, null);
    final file = File('$home/.config/uim/color.json5');
    if (!file.existsSync()) return Colors._(styles, null);
    try {
      styles.addAll(_parse(file.readAsStringSync()));
      return Colors._(styles, null);
    } on Exception catch (e) {
      return Colors._(styles, '~/.config/uim/color.json5: $e');
    }
  }

  static Map<String, String?> _parse(String text) {
    final json = JSON5.parse(text);
    if (json is! Map) throw const FormatException('expected an object');
    final styles = <String, String?>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (value is! String?) {
        throw FormatException('"$key" must be a string or null');
      }
      styles[key as String] = value != null && value.startsWith('#')
          ? _rgb(key, value)
          : value;
    }
    return styles;
  }

  /// Turns `#rrggbb` into the SGR parameters of that 24-bit color, as the
  /// background color for keys ending in `.background`.
  static String _rgb(String key, String value) {
    final match = RegExp(
      r'^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$',
    ).firstMatch(value);
    if (match == null) {
      throw FormatException('"$key": "$value" is not a #rrggbb color');
    }
    final [r, g, b] = [
      for (var i = 1; i <= 3; i++) int.parse(match.group(i)!, radix: 16),
    ];
    return '${key.endsWith('.background') ? 48 : 38};2;$r;$g;$b';
  }

  /// SGR parameters for text matching the search: the current match (the one
  /// the cursor is on) or another one.
  String searchStyle({required bool current}) {
    final prefix = current ? 'search.current' : 'search';
    return [
      _styles['$prefix.foreground'],
      _styles['$prefix.background'],
    ].where((s) => s != null && s.isNotEmpty).join(';');
  }

  final Map<String, String?> _styles;

  /// Why the user's file was not used, if it was not.
  final String? error;

  /// Style of a capture, or null if it should not affect highlighting.
  ///
  /// A name without a style (missing or null) uses the style of the name
  /// without its last `.part`; a name not found at all gets `''`, the default
  /// color. Names starting with `_` only exist for predicates to refer to.
  String? styleFor(String name) {
    if (_ignored.contains(name) || name.startsWith('_')) return null;
    var n = name;
    while (true) {
      final style = _styles[n];
      if (style != null) return style;
      final dot = n.lastIndexOf('.');
      if (dot < 0) return '';
      n = n.substring(0, dot);
    }
  }
}
