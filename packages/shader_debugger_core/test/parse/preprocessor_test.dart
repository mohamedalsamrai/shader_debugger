import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:shader_debugger_core/src/parse/preprocessor.dart';
import 'package:shader_debugger_core/src/parse/token.dart';
import 'package:test/test.dart';

({List<Token> tokens, List<Diagnostic> diagnostics}) preprocess(
  String source, {
  IncludeResolver? resolveInclude,
  Map<String, String> defines = const {},
}) {
  final preprocessor = Preprocessor(
    SourceFile.fromString(source),
    resolveInclude: resolveInclude,
    defines: defines,
  );
  return (tokens: preprocessor.run(), diagnostics: preprocessor.diagnostics);
}

String output(String source, {Map<String, String> defines = const {}}) =>
    preprocess(source, defines: defines).tokens.map((t) => t.text).join(' ');

List<String> messages(String source, {IncludeResolver? resolveInclude}) => [
  for (final d in preprocess(
    source,
    resolveInclude: resolveInclude,
  ).diagnostics)
    '${d.severity.name}: ${d.message}',
];

void main() {
  group('macros', () {
    test('expands an object-like macro at the place it is used', () {
      const source = '#define N 4\nfloat a[N];';
      final tokens = preprocess(source).tokens;
      expect(tokens.map((t) => t.text), ['float', 'a', '[', '4', ']', ';']);
      final four = tokens[3];
      expect(four.origin, TokenOrigin.macro);
      expect(source.substring(four.offset, four.end), 'N');
      expect(tokens.first.origin, TokenOrigin.source);
    });

    test('expands a function-like macro and its arguments', () {
      const source =
          '#define SAT(x) clamp(x, 0.0, 1.0)\n'
          'float y = SAT(a + b);';
      final tokens = preprocess(source).tokens;
      expect(
        tokens.map((t) => t.text).join(' '),
        'float y = clamp ( a + b , 0.0 , 1.0 ) ;',
      );
      final expanded = tokens.where((t) => t.origin == TokenOrigin.macro);
      expect(expanded, hasLength(10));
      for (final token in expanded) {
        expect(source.substring(token.offset, token.end), 'SAT(a + b)');
      }
    });

    test('a space before ( makes an object-like macro', () {
      expect(output('#define F (x)\nF(1)'), '( x ) ( 1 )');
    });

    test('a function-like macro name without ( is left alone', () {
      expect(output('#define F(x) x\nF + 1'), 'F + 1');
    });

    test('nested macros expand; a macro does not expand itself', () {
      expect(
        output('#define TWO (ONE + ONE)\n#define ONE 1\nTWO'),
        '( 1 + 1 )',
      );
      expect(output('#define A B\n#define B A\nA'), 'A');
    });

    test('## pastes tokens', () {
      expect(output('#define CAT(a, b) a##b\nCAT(foo, Bar)'), 'fooBar');
    });

    test('#undef removes a macro', () {
      expect(output('#define N 1\n#undef N\nN'), 'N');
    });

    test('defines from the caller apply from the first line', () {
      expect(output('QUALITY', defines: {'QUALITY': '3'}), '3');
    });

    test('reports a call with the wrong number of arguments', () {
      expect(messages('#define F(a, b) a\nF(1)'), [
        'warning: Macro F takes 2 argument(s), not 1.',
      ]);
    });
  });

  group('conditionals', () {
    test('#ifdef, #ifndef, #else', () {
      const source = '''
#ifdef MISSING
a
#else
b
#endif
#ifndef MISSING
c
#endif''';
      expect(output(source), 'b c');
    });

    test('#if with defined(), arithmetic and #elif', () {
      const source = '''
#define LEVEL 3
#if defined(LEVEL) && LEVEL * 2 > 7
high
#elif LEVEL >= 3
mid
#else
low
#endif''';
      expect(output(source), 'mid');
    });

    test('a group inside an inactive branch stays inactive', () {
      const source = '''
#if 0
#ifndef X
hidden
#else
hidden too
#endif
#endif
shown''';
      expect(output(source), 'shown');
    });

    test('IMPELLER_GRAPHICS_BACKEND is defined', () {
      expect(
        output('#ifdef IMPELLER_GRAPHICS_BACKEND\nimpeller\n#endif'),
        'impeller',
      );
    });

    test('reports problems without stopping', () {
      expect(messages('#if 1 / 0\nx\n#endif'), [
        'warning: In #if: division by zero.',
      ]);
      expect(messages('#ifdef A\nx'), ['warning: Missing #endif.']);
      expect(messages('#endif'), ['warning: #endif without #if.']);
    });
  });

  group('includes', () {
    test('runtime_effect.glsl becomes the FlutterFragCoord stub', () {
      const source = '#include <flutter/runtime_effect.glsl>\nvoid main() {}';
      final tokens = preprocess(source).tokens;
      expect(
        tokens.map((t) => t.text).join(' '),
        'vec2 FlutterFragCoord ( ) ; void main ( ) { }',
      );
      final stub = tokens.takeWhile((t) => t.text != 'void');
      for (final token in stub) {
        expect(token.origin, TokenOrigin.include);
        expect(
          source.substring(token.offset, token.end),
          '#include <flutter/runtime_effect.glsl>',
        );
      }
    });

    test('other includes are read through the resolver', () {
      final files = {
        'noise.glsl':
            '#ifndef NOISE\n#define NOISE\nfloat noise(vec2 p);\n#endif\n',
      };
      final result = preprocess(
        '#include "noise.glsl"\n#include "noise.glsl"\nNOISE',
        resolveInclude: (path) => files[path],
      );
      expect(
        result.tokens.map((t) => t.text).join(' '),
        'float noise ( vec2 p ) ;',
        reason: 'the include guard stops the second copy',
      );
      expect(result.diagnostics, isEmpty);
    });

    test('an include that cannot be read is reported and skipped', () {
      expect(messages('#include <lygia/math.glsl>\nx'), [
        "warning: Cannot read 'lygia/math.glsl'; what it declares is unknown to the debugger.",
      ]);
    });
  });

  test('ignores #version, #extension and #pragma; reports the rest', () {
    expect(
      output('#version 460 core\n#extension GL_X : enable\n#pragma once\nx'),
      'x',
    );
    expect(messages('#error stop here\n#frobnicate'), [
      'error: #error stop here',
      'warning: Unknown directive #frobnicate.',
    ]);
  });
}
