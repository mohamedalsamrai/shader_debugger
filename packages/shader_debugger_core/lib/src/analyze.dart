/// The analyzer's entry point.
library;

import 'package:source_span/source_span.dart';

import 'model/shader_analysis.dart';
import 'parse/parser.dart';
import 'parse/preprocessor.dart';
import 'parse/resolver.dart';

export 'parse/preprocessor.dart' show IncludeResolver;

/// Analyzes a Flutter fragment shader: preprocess, parse, then resolve
/// (design doc §5).
///
/// [url] names the file in spans and diagnostics. The
/// `flutter/runtime_effect.glsl` include is understood without help; other
/// includes are read through [resolveInclude], and without it they are
/// reported and skipped. [defines] adds macros, as if `#define`d before the first line;
/// `IMPELLER_GRAPHICS_BACKEND` is always defined.
///
/// Never throws for bad input: problems become [ShaderAnalysis.diagnostics],
/// and statements the analyzer does not understand are not pickable.
ShaderAnalysis analyzeShader(
  String source, {
  Uri? url,
  IncludeResolver? resolveInclude,
  Map<String, String> defines = const {},
}) {
  final file = SourceFile.fromString(source, url: url);
  final preprocessor = Preprocessor(
    file,
    resolveInclude: resolveInclude,
    defines: defines,
  );
  final tokens = preprocessor.run();
  final parser = Parser(tokens, file);
  final unit = parser.parse();
  return Resolver(
    file,
    unit,
  ).resolve(earlier: [...preprocessor.diagnostics, ...parser.diagnostics]);
}
