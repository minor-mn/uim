// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'queries.g.dart';
import 'tree_sitter_ffi.dart';

/// A language uim can highlight.
class Language {
  const Language(
    this.load,
    this.highlights, {
    this.extensions = const [],
    this.fileNames = const [],
  });

  final Pointer<TSLanguage> Function() load;
  final String highlights;
  final List<String> extensions;
  final List<String> fileNames;
}

final languages = [
  Language(
    () => tree_sitter_bash(),
    bashHighlights,
    extensions: ['sh', 'bash', 'zsh'],
    fileNames: ['.bashrc', '.bash_profile', '.zshrc', '.zprofile'],
  ),
  Language(() => tree_sitter_c(), cHighlights, extensions: ['c', 'h']),
  Language(
    () => tree_sitter_cpp(),
    cppHighlights,
    extensions: ['cc', 'cpp', 'cxx', 'hh', 'hpp', 'hxx'],
  ),
  Language(() => tree_sitter_crystal(), crystalHighlights, extensions: ['cr']),
  Language(() => tree_sitter_css(), cssHighlights, extensions: ['css']),
  Language(() => tree_sitter_dart(), dartHighlights, extensions: ['dart']),
  Language(
    () => tree_sitter_elixir(),
    elixirHighlights,
    extensions: ['ex', 'exs'],
  ),
  Language(
    () => tree_sitter_erlang(),
    erlangHighlights,
    extensions: ['erl', 'hrl'],
  ),
  Language(
    () => tree_sitter_groovy(),
    groovyHighlights,
    extensions: ['groovy', 'gradle'],
    fileNames: ['Jenkinsfile'],
  ),
  Language(
    () => tree_sitter_html(),
    htmlHighlights,
    extensions: ['html', 'htm'],
  ),
  Language(
    () => tree_sitter_ini(),
    iniHighlights,
    extensions: ['ini', 'cfg', 'conf'],
    fileNames: ['.editorconfig', '.gitconfig'],
  ),
  Language(
    () => tree_sitter_javascript(),
    javascriptHighlights,
    extensions: ['js', 'mjs', 'cjs', 'jsx'],
  ),
  Language(() => tree_sitter_json(), jsonHighlights, extensions: ['json']),
  Language(
    () => tree_sitter_json5(),
    json5Highlights,
    extensions: ['json5', 'jsonc'],
  ),
  Language(
    () => tree_sitter_kotlin(),
    kotlinHighlights,
    extensions: ['kt', 'kts'],
  ),
  Language(
    () => tree_sitter_properties(),
    propertiesHighlights,
    extensions: ['properties'],
  ),
  Language(
    () => tree_sitter_ruby(),
    rubyHighlights,
    extensions: ['rb', 'rake', 'gemspec'],
    fileNames: ['Gemfile', 'Rakefile'],
  ),
  Language(() => tree_sitter_swift(), swiftHighlights, extensions: ['swift']),
  Language(() => tree_sitter_tsx(), tsxHighlights, extensions: ['tsx']),
  Language(
    () => tree_sitter_typescript(),
    typescriptHighlights,
    extensions: ['ts', 'mts', 'cts'],
  ),
  Language(
    () => tree_sitter_xml(),
    xmlHighlights,
    extensions: ['xml', 'plist', 'svg'],
  ),
  Language(
    () => tree_sitter_yaml(),
    yamlHighlights,
    extensions: ['yaml', 'yml'],
  ),
];

Language? languageForPath(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 ? name.substring(dot + 1) : null;
  for (final language in languages) {
    if (language.fileNames.contains(name) ||
        (extension != null && language.extensions.contains(extension))) {
      return language;
    }
  }
  return null;
}

// Each grammar is its own library; see hook/build.dart.

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/bash')
external Pointer<TSLanguage> tree_sitter_bash();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/c')
external Pointer<TSLanguage> tree_sitter_c();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/cpp')
external Pointer<TSLanguage> tree_sitter_cpp();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/crystal')
external Pointer<TSLanguage> tree_sitter_crystal();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/css')
external Pointer<TSLanguage> tree_sitter_css();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/dart')
external Pointer<TSLanguage> tree_sitter_dart();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/elixir')
external Pointer<TSLanguage> tree_sitter_elixir();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/erlang')
external Pointer<TSLanguage> tree_sitter_erlang();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/groovy')
external Pointer<TSLanguage> tree_sitter_groovy();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/html')
external Pointer<TSLanguage> tree_sitter_html();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/ini')
external Pointer<TSLanguage> tree_sitter_ini();

@Native<Pointer<TSLanguage> Function()>(
  assetId: 'package:uim/grammar/javascript',
)
external Pointer<TSLanguage> tree_sitter_javascript();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/json')
external Pointer<TSLanguage> tree_sitter_json();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/json5')
external Pointer<TSLanguage> tree_sitter_json5();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/kotlin')
external Pointer<TSLanguage> tree_sitter_kotlin();

@Native<Pointer<TSLanguage> Function()>(
  assetId: 'package:uim/grammar/properties',
)
external Pointer<TSLanguage> tree_sitter_properties();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/ruby')
external Pointer<TSLanguage> tree_sitter_ruby();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/swift')
external Pointer<TSLanguage> tree_sitter_swift();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/tsx')
external Pointer<TSLanguage> tree_sitter_tsx();

@Native<Pointer<TSLanguage> Function()>(
  assetId: 'package:uim/grammar/typescript',
)
external Pointer<TSLanguage> tree_sitter_typescript();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/xml')
external Pointer<TSLanguage> tree_sitter_xml();

@Native<Pointer<TSLanguage> Function()>(assetId: 'package:uim/grammar/yaml')
external Pointer<TSLanguage> tree_sitter_yaml();
