/// Display width helpers. Columns are counted in terminal cells.
library;

const tabStop = 8;

/// Width in cells of [rune] when it starts at display column [disp].
int cellWidth(int rune, int disp) {
  if (rune == 0x09) return tabStop - disp % tabStop;
  if (rune < 0x20 || rune == 0x7f) return 2; // shown as ^X
  if (_isZeroWidth(rune)) return 0;
  return _isWide(rune) ? 2 : 1;
}

/// Text drawn for [rune] occupying [width] cells.
String glyph(int rune, int width) {
  if (rune == 0x09) return ' ' * width;
  if (rune < 0x20 || rune == 0x7f) {
    return '^${String.fromCharCode(rune ^ 0x40)}';
  }
  return String.fromCharCode(rune);
}

/// Display column where the rune at index [col] of [line] starts.
int dispCol(List<int> line, int col) {
  var d = 0;
  for (var i = 0; i < col && i < line.length; i++) {
    d += cellWidth(line[i], d);
  }
  return d;
}

/// Index of the rune of [line] covering display column [want].
int colAtDisp(List<int> line, int want) {
  var d = 0;
  for (var i = 0; i < line.length; i++) {
    final w = cellWidth(line[i], d);
    if (want < d + w) return i;
    d += w;
  }
  return line.isEmpty ? 0 : line.length - 1;
}

int stringWidth(String s) {
  var d = 0;
  for (final r in s.runes) {
    d += cellWidth(r, d);
  }
  return d;
}

/// Cuts [s] so that it fits in [cols] cells.
String fitWidth(String s, int cols) {
  final sb = StringBuffer();
  var d = 0;
  for (final r in s.runes) {
    final w = cellWidth(r, d);
    if (d + w > cols) break;
    sb.write(glyph(r, w));
    d += w;
  }
  return sb.toString();
}

bool _isZeroWidth(int r) =>
    (r >= 0x0300 && r <= 0x036f) ||
    (r >= 0x200b && r <= 0x200f) ||
    (r >= 0x3099 && r <= 0x309a) ||
    (r >= 0xfe00 && r <= 0xfe0f);

bool _isWide(int r) =>
    (r >= 0x1100 && r <= 0x115f) ||
    (r >= 0x2e80 && r <= 0x303e) ||
    (r >= 0x3041 && r <= 0x33ff) ||
    (r >= 0x3400 && r <= 0x4dbf) ||
    (r >= 0x4e00 && r <= 0x9fff) ||
    (r >= 0xa000 && r <= 0xa4cf) ||
    (r >= 0xac00 && r <= 0xd7a3) ||
    (r >= 0xf900 && r <= 0xfaff) ||
    (r >= 0xfe30 && r <= 0xfe4f) ||
    (r >= 0xff00 && r <= 0xff60) ||
    (r >= 0xffe0 && r <= 0xffe6) ||
    (r >= 0x1f300 && r <= 0x1f64f) ||
    (r >= 0x1f900 && r <= 0x1f9ff) ||
    (r >= 0x20000 && r <= 0x3fffd);
