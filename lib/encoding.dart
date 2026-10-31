import 'dart:convert';

import 'src/cp932.g.dart';

/// Character encodings uim reads and writes.
enum TextEncoding {
  utf8('UTF-8'),
  utf8Bom('UTF-8 BOM'),
  utf16le('UTF-16LE'),
  utf16be('UTF-16BE'),
  utf32le('UTF-32LE'),
  utf32be('UTF-32BE'),
  cp932('CP932');

  const TextEncoding(this.label);

  final String label;
}

/// Line endings uim reads and writes.
enum LineEnding {
  lf('LF', '\n'),
  crlf('CRLF', '\r\n'),
  cr('CR', '\r');

  const LineEnding(this.label, this.text);

  final String label;
  final String text;
}

const _bom = [0xef, 0xbb, 0xbf];

/// Decodes a file: UTF-8, UTF-16 or UTF-32 with a BOM, else UTF-8 if valid,
/// else CP932 if valid, else UTF-8 with invalid bytes replaced. UTF-16 and
/// UTF-32 are only recognized by their BOM.
(String, TextEncoding) decodeText(List<int> bytes) {
  final wide = _decodeWide(bytes);
  if (wide != null) return wide;
  if (bytes.length >= 3 &&
      bytes[0] == _bom[0] &&
      bytes[1] == _bom[1] &&
      bytes[2] == _bom[2]) {
    return (
      utf8.decode(bytes.sublist(3), allowMalformed: true),
      TextEncoding.utf8Bom,
    );
  }
  try {
    return (utf8.decode(bytes), TextEncoding.utf8);
  } on FormatException {
    final text = _decodeCp932(bytes);
    if (text != null) return (text, TextEncoding.cp932);
    return (utf8.decode(bytes, allowMalformed: true), TextEncoding.utf8);
  }
}

/// Encodes [text], or returns null if it has a character [encoding] cannot
/// represent.
List<int>? encodeText(String text, TextEncoding encoding) => switch (encoding) {
  TextEncoding.utf8 => utf8.encode(text),
  TextEncoding.utf8Bom => [..._bom, ...utf8.encode(text)],
  TextEncoding.utf16le => _encodeUtf16(text, bigEndian: false),
  TextEncoding.utf16be => _encodeUtf16(text, bigEndian: true),
  TextEncoding.utf32le => _encodeUtf32(text, bigEndian: false),
  TextEncoding.utf32be => _encodeUtf32(text, bigEndian: true),
  TextEncoding.cp932 => _encodeCp932(text),
};

/// The line ending of the first line break in [text]; LF if there is none.
LineEnding detectLineEnding(String text) {
  final i = text.indexOf(RegExp('[\r\n]'));
  if (i < 0 || text[i] == '\n') return LineEnding.lf;
  return i + 1 < text.length && text[i + 1] == '\n'
      ? LineEnding.crlf
      : LineEnding.cr;
}

/// Lines of [text], split at any of CRLF, CR and LF.
List<String> splitLines(String text) => text.split(RegExp('\r\n|\r|\n'));

/// UTF-16 or UTF-32 by its BOM, when the length is a whole number of units.
/// UTF-32LE is checked first, as its BOM starts with that of UTF-16LE.
/// Null if there is no such BOM, or UTF-32 has a value that is not a
/// character.
(String, TextEncoding)? _decodeWide(List<int> bytes) {
  bool starts(List<int> bom) {
    if (bytes.length < bom.length) return false;
    for (var i = 0; i < bom.length; i++) {
      if (bytes[i] != bom[i]) return false;
    }
    return true;
  }

  if (bytes.length % 4 == 0) {
    for (final (bom, encoding) in [
      ([0x00, 0x00, 0xfe, 0xff], TextEncoding.utf32be),
      ([0xff, 0xfe, 0x00, 0x00], TextEncoding.utf32le),
    ]) {
      if (!starts(bom)) continue;
      final text = _decodeUtf32(
        bytes,
        bigEndian: encoding == TextEncoding.utf32be,
      );
      return text == null ? null : (text, encoding);
    }
  }
  if (bytes.length.isEven) {
    if (starts([0xfe, 0xff])) {
      return (_decodeUtf16(bytes, bigEndian: true), TextEncoding.utf16be);
    }
    if (starts([0xff, 0xfe])) {
      return (_decodeUtf16(bytes, bigEndian: false), TextEncoding.utf16le);
    }
  }
  return null;
}

/// The text after the BOM, or null if a value is above U+10FFFF.
String? _decodeUtf32(List<int> bytes, {required bool bigEndian}) {
  final runes = <int>[];
  for (var i = 4; i < bytes.length; i += 4) {
    final b = bytes.sublist(i, i + 4);
    final rune = bigEndian
        ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0];
    if (rune > 0x10ffff) return null;
    runes.add(rune);
  }
  return String.fromCharCodes(runes);
}

List<int> _encodeUtf32(String text, {required bool bigEndian}) => [
  ...(bigEndian ? [0x00, 0x00, 0xfe, 0xff] : [0xff, 0xfe, 0x00, 0x00]),
  for (final rune in text.runes)
    ...(bigEndian
        ? [rune >> 24, rune >> 16 & 0xff, rune >> 8 & 0xff, rune & 0xff]
        : [rune & 0xff, rune >> 8 & 0xff, rune >> 16 & 0xff, rune >> 24]),
];

/// The text after the BOM. Unpaired surrogates are kept as they are, so they
/// are written back unchanged.
String _decodeUtf16(List<int> bytes, {required bool bigEndian}) {
  final units = [
    for (var i = 2; i < bytes.length; i += 2)
      bigEndian ? bytes[i] << 8 | bytes[i + 1] : bytes[i + 1] << 8 | bytes[i],
  ];
  return String.fromCharCodes(units);
}

List<int> _encodeUtf16(String text, {required bool bigEndian}) => [
  ...(bigEndian ? [0xfe, 0xff] : [0xff, 0xfe]),
  for (final unit in text.codeUnits)
    ...(bigEndian ? [unit >> 8, unit & 0xff] : [unit & 0xff, unit >> 8]),
];

int _leadIndex(int b) => b >= 0x81 && b <= 0x9f
    ? b - 0x81
    : b >= 0xe0 && b <= 0xfc
    ? b - 0xe0 + 31
    : -1;

String? _decodeCp932(List<int> bytes) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    final lead = _leadIndex(b);
    if (lead < 0) {
      final u = cp932Single[b];
      if (u == 0 && b != 0) return null;
      out.writeCharCode(u);
      continue;
    }
    if (i + 1 >= bytes.length) return null;
    final trail = bytes[++i];
    if (trail < 0x40 || trail > 0xfc) return null;
    final u = cp932Double[lead * 189 + trail - 0x40];
    if (u == 0) return null;
    out.writeCharCode(u);
  }
  return out.toString();
}

/// Code point to CP932 bytes (one byte, or lead << 8 | trail). For a
/// character with several codes, the first in byte order, which is what
/// Windows (and Python's cp932) writes.
final Map<int, int> _cp932Encode = () {
  final map = <int, int>{};
  for (var i = 0; i < cp932Double.length; i++) {
    final u = cp932Double[i];
    if (u == 0 || map.containsKey(u)) continue;
    final leadIndex = i ~/ 189;
    final lead = leadIndex < 31 ? 0x81 + leadIndex : 0xe0 + leadIndex - 31;
    map[u] = lead << 8 | (0x40 + i % 189);
  }
  for (var b = 0; b < 256; b++) {
    final u = cp932Single[b];
    if ((u != 0 || b == 0) && _leadIndex(b) < 0) map.putIfAbsent(u, () => b);
  }
  return map;
}();

List<int>? _encodeCp932(String text) {
  final out = <int>[];
  for (final r in text.runes) {
    final code = _cp932Encode[r];
    if (code == null) return null;
    if (code > 0xff) {
      out
        ..add(code >> 8)
        ..add(code & 0xff);
    } else {
      out.add(code);
    }
  }
  return out;
}
