/// Pure-Dart core of the Flutter shader debugger.
///
/// It turns a Flutter fragment shader (`.frag`) into the facts the variable
/// picker needs: types, scopes, symbols and what each statement writes. The
/// preprocessor, parser and instrumenter build on this model.
///
/// It has no `dart:io` or Flutter dependency, so it runs both in the DevTools
/// extension (Flutter web) and in a command-line tool.
library;

export 'package:source_span/source_span.dart'
    show FileLocation, FileSpan, SourceFile;

export 'src/model/glsl_type.dart';
export 'src/model/shader_analysis.dart';
export 'src/model/statement_info.dart';
export 'src/model/symbols.dart';
