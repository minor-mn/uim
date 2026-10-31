import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Source directory of each grammar. Must match lib/src/languages.dart.
const grammars = {
  'bash': 'third_party/tree-sitter-bash/src',
  'c': 'third_party/tree-sitter-c/src',
  'cpp': 'third_party/tree-sitter-cpp/src',
  'crystal': 'third_party/tree-sitter-crystal/src',
  'css': 'third_party/tree-sitter-css/src',
  'dart': 'third_party/tree-sitter-dart/src',
  'elixir': 'third_party/tree-sitter-elixir/src',
  'erlang': 'third_party/tree-sitter-erlang/src',
  'groovy': 'third_party/tree-sitter-groovy/src',
  'html': 'third_party/tree-sitter-html/src',
  'ini': 'third_party/tree-sitter-ini/src',
  'javascript': 'third_party/tree-sitter-javascript/src',
  'json': 'third_party/tree-sitter-json/src',
  'json5': 'third_party/tree-sitter-json5/src',
  'kotlin': 'third_party/tree-sitter-kotlin/src',
  'properties': 'third_party/tree-sitter-properties/src',
  'ruby': 'third_party/tree-sitter-ruby/src',
  'swift': 'third_party/tree-sitter-swift/src',
  'tsx': 'third_party/tree-sitter-typescript/tsx/src',
  'typescript': 'third_party/tree-sitter-typescript/typescript/src',
  'xml': 'third_party/tree-sitter-xml/xml/src',
  'yaml': 'third_party/tree-sitter-yaml/src',
};

/// Compiles tree-sitter and each grammar into its own library, in parallel.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final core = CBuilder.library(
      name: 'tree_sitter',
      assetName: 'src/tree_sitter_ffi.dart',
      sources: ['third_party/tree-sitter/lib/src/lib.c'],
      includes: [
        'third_party/tree-sitter/lib/include',
        'third_party/tree-sitter/lib/src',
      ],
      std: 'c11',
      defines: {
        '_POSIX_C_SOURCE': '200112L',
        '_DEFAULT_SOURCE': null,
        '_DARWIN_C_SOURCE': null,
      },
    );
    final languages = [
      for (final MapEntry(key: name, value: dir) in grammars.entries)
        CBuilder.library(
          name: 'tree_sitter_$name',
          assetName: 'grammar/$name',
          sources: [
            '$dir/parser.c',
            if (File.fromUri(input.packageRoot.resolve('$dir/scanner.c'))
                .existsSync())
              '$dir/scanner.c',
          ],
          includes: [dir],
          std: 'c11',
          optimizationLevel: OptimizationLevel.o2,
        ),
    ];
    await Future.wait([
      for (final builder in [core, ...languages])
        builder.run(input: input, output: output),
    ]);
  });
}
