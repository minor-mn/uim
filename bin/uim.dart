import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uim/editor.dart';
import 'package:uim/terminal.dart';

void main(List<String> args) {
  if (args.length > 1) {
    stderr.writeln('usage: uim [file]');
    exit(2);
  }
  if (!stdin.hasTerminal || !stdout.hasTerminal) {
    stderr.writeln('uim: input and output must be a terminal');
    exit(1);
  }

  final editor = Editor(args.isEmpty ? null : args.first);
  final terminal = Terminal();

  void draw() =>
      stdout.write(editor.render(stdout.terminalLines, stdout.terminalColumns));

  Future<void> finish() async {
    terminal.leave();
    await stdout.flush();
    exit(0);
  }

  // Gives up on a request to the shared register after a while, such as when
  // uim runs outside fm-ee2e and nothing answers.
  Timer? timer;
  var timerRequest = -1;
  void watchRegister() {
    if (!editor.waitingForRegister && editor.sharedRegister != null) {
      timer?.cancel();
      timer = null;
      return;
    }
    if (timer != null && timerRequest == editor.registerRequest) return;
    timer?.cancel();
    final request = timerRequest = editor.registerRequest;
    timer = Timer(const Duration(seconds: 2), () {
      timer = null;
      editor.registerTimedOut(request);
      if (editor.quit) {
        finish();
        return;
      }
      watchRegister();
      draw();
    });
  }

  runZonedGuarded(
    () {
      terminal.enter();
      editor
        ..send = stdout.write
        ..probeSharedRegister();
      watchRegister();
      draw();
      ProcessSignal.sigwinch.watch().listen((_) => draw());
      ProcessSignal.sigint.watch().listen((_) {
        editor.interrupt();
        draw();
      });
      final parser = KeyParser();
      stdin.transform(const Utf8Decoder(allowMalformed: true)).listen((input) {
        for (final key in parser.feed(input)) {
          editor.handleKey(key);
          if (editor.quit) {
            finish();
            return;
          }
        }
        watchRegister();
        draw();
      });
    },
    (error, stack) {
      terminal.leave();
      stderr.writeln('uim: $error\n$stack');
      exit(1);
    },
  );
}
