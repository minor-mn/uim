import 'dart:io';

/// Puts the terminal into raw mode on the alternate screen and back, with
/// bracketed paste on.
class Terminal {
  bool _active = false;

  void enter() {
    stdin.echoMode = false;
    stdin.lineMode = false;
    stdout.write('\x1b[?1049h\x1b[?2004h');
    _active = true;
  }

  void leave() {
    if (!_active) return;
    _active = false;
    stdout.write('\x1b[?2004l\x1b[?1049l\x1b[?25h');
    stdin.lineMode = true;
    stdin.echoMode = true;
  }
}

/// Prefix of the key for a reply from the shared register (OSC 7520, kept by
/// fm-ee2e). The rest is `line;Base64`, `char;Base64` or `empty`.
const registerReplyKey = '<Register>';

/// Prefix of the key for bracketed-paste text. The rest is the pasted text.
const pasteKey = '<Paste>';

/// Splits raw terminal input into keys.
///
/// Printable characters are returned as themselves (one rune); special keys
/// as names such as `<Esc>`, `<CR>`, `<BS>`, `<C-r>` and `<Up>`, and replies
/// and pastes as [registerReplyKey] and [pasteKey] followed by their contents.
/// An OSC, CSI or paste cut off at the end of the input is kept until the
/// next input completes it.
class KeyParser {
  List<int> _pending = const [];

  List<String> feed(String input) {
    final keys = <String>[];
    final r = [..._pending, ...input.runes];
    _pending = const [];
    var i = 0;
    while (i < r.length) {
      final c = r[i];
      if (c == 0x1b && i + 1 < r.length && r[i + 1] == 0x5d) {
        // OSC (ESC ]), ended by BEL or ST (ESC \).
        var end = -1;
        var next = -1;
        for (var j = i + 2; j < r.length; j++) {
          if (r[j] == 0x07) {
            (end, next) = (j, j + 1);
          } else if (r[j] == 0x1b && j + 1 < r.length) {
            // ST, or another sequence cutting the OSC short.
            (end, next) = (j, r[j + 1] == 0x5c ? j + 2 : j);
          } else {
            continue;
          }
          break;
        }
        if (end < 0) {
          _pending = r.sublist(i);
          break;
        }
        final body = String.fromCharCodes(r.sublist(i + 2, end));
        if (body.startsWith('7520;')) {
          keys.add(registerReplyKey + body.substring(5));
        }
        i = next;
        continue;
      }
      if (c == 0x1b &&
          i + 1 < r.length &&
          (r[i + 1] == 0x5b || r[i + 1] == 0x4f)) {
        // CSI (ESC [) or SS3 (ESC O) sequence: skip to its final byte.
        var j = i + 2;
        while (j < r.length && (r[j] < 0x40 || r[j] > 0x7e)) {
          j++;
        }
        if (j < r.length) {
          final params = String.fromCharCodes(r.sublist(i + 2, j));
          if (r[j] == 0x7e && params == '200') {
            final end = _indexOf(r, _pasteEnd, j + 1);
            if (end < 0) {
              _pending = r.sublist(i);
              break;
            }
            keys.add(pasteKey + String.fromCharCodes(r.sublist(j + 1, end)));
            i = end + _pasteEnd.length;
            continue;
          }
          final name = switch ((r[j], params)) {
            (0x41, _) => '<Up>',
            (0x42, _) => '<Down>',
            (0x43, _) => '<Right>',
            (0x44, _) => '<Left>',
            (0x7e, '5') => '<PageUp>',
            (0x7e, '6') => '<PageDown>',
            _ => null,
          };
          if (name != null) keys.add(name);
          i = j + 1;
          continue;
        }
        if (r[i + 1] == 0x5b) {
          _pending = r.sublist(i);
          break;
        }
      }
      if (c == 0x1b) {
        keys.add('<Esc>');
      } else if (c == 0x0d || c == 0x0a) {
        keys.add('<CR>');
      } else if (c == 0x7f || c == 0x08) {
        keys.add('<BS>');
      } else if (c == 0x12) {
        keys.add('<C-r>');
      } else if (c >= 0x20 || c == 0x09) {
        keys.add(String.fromCharCode(c));
      }
      i++;
    }
    return keys;
  }

  static const _pasteEnd = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]; // ESC [201~

  static int _indexOf(List<int> r, List<int> pattern, int from) {
    outer:
    for (var i = from; i + pattern.length <= r.length; i++) {
      for (var k = 0; k < pattern.length; k++) {
        if (r[i + k] != pattern[k]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
