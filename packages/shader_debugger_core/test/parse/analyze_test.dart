import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

/// Analyzes [body] as the body of `main`, after [globals].
ShaderAnalysis analyzeMain(String body, {String globals = ''}) =>
    analyzeShader('''
#version 460 core
#include <flutter/runtime_effect.glsl>
out vec4 fragColor;
$globals
void main() {
$body
}
''');

/// The first statement whose source starts with [text].
StatementInfo statement(ShaderAnalysis analysis, String text) =>
    analysis.statements.firstWhere((s) => s.span.text.startsWith(text));

List<String> names(Iterable<GlslSymbol> symbols) => [
  for (final symbol in symbols) symbol.name,
];

VariableSymbol variable(ShaderAnalysis analysis, String name) => analysis
    .symbols
    .symbols
    .whereType<VariableSymbol>()
    .lastWhere((v) => v.name == name);

void main() {
  test('reads the idioms of the Flutter SDK shaders', () {
    final analysis = analyzeShader('''
#version 320 es
precision highp float;
#include <flutter/runtime_effect.glsl>

layout(location = 0) uniform vec4 u_color;
layout(location = 0) out vec4 fragColor;

const float PI = 3.14159;
float u_alpha = u_color.a;

float turbulence(highp vec2 uv) { return uv.x; }

void main() {
  vec2 p = FlutterFragCoord();
  float turbulence = turbulence(p);
  fragColor = vec4(turbulence * PI * u_alpha);
}
''');
    expect(analysis.diagnostics, isEmpty);
    expect(names(analysis.uniforms), ['u_color']);
    expect(variable(analysis, 'fragColor').kind, VariableKind.output);
    expect(variable(analysis, 'PI').isConst, isTrue);
    expect(variable(analysis, 'u_alpha').kind, VariableKind.global);

    // The local is visible only after its initializer, so the call in the
    // initializer still means the function.
    final declaration = statement(analysis, 'float turbulence =');
    final local = declaration.defaultPick!;
    expect(local.kind, VariableKind.local);
    final call = analysis.source.getText(0).indexOf('turbulence(p)');
    expect(local.scope.lookupFunctions('turbulence', at: call), hasLength(1));
    expect(names(statement(analysis, 'fragColor =').inScope), [
      'p', 'turbulence', 'u_color', 'fragColor', 'PI', 'u_alpha', //
    ]);
  });

  group('writes', () {
    test('assignment targets, through fields and indices', () {
      final analysis = analyzeMain('''
  vec2 uv = vec2(0.0);
  float w[3];
  uv.x = 1.0;
  w[1] = uv.y;
  uv += vec2(w[1]);
''');
      expect(names(statement(analysis, 'uv.x =').writes), ['uv']);
      expect(names(statement(analysis, 'w[1] =').writes), ['w']);
      expect(names(statement(analysis, 'uv +=').writes), ['uv']);
      expect(
        statement(analysis, 'float w[3]').writes,
        isEmpty,
        reason: 'no initializer, so nothing written',
      );
    });

    test('++ and --, and chained assignments in source order', () {
      final analysis = analyzeMain('''
  int i = 0;
  int j = 0;
  i++;
  --j;
  i = j = 3;
''');
      expect(names(statement(analysis, 'i++').writes), ['i']);
      expect(names(statement(analysis, '--j').writes), ['j']);
      expect(names(statement(analysis, 'i = j = 3').writes), ['i', 'j']);
    });

    test('arguments passed to out and inout parameters', () {
      final analysis = analyzeMain(
        '''
  float r = 0.0;
  vec2 q = vec2(0.0);
  float k = 1.0;
  split(r, q, k);
  float whole;
  float part = modf(k, whole);
''',
        globals: '''
void split(out float r, inout vec2 q, float k) {
  r = k;
  q *= k;
}
''',
      );
      expect(names(statement(analysis, 'split(').writes), ['r', 'q']);
      expect(names(statement(analysis, 'float part').writes), [
        'part',
        'whole',
      ]);
      final parameter = analysis.symbols.symbols
          .whereType<VariableSymbol>()
          .firstWhere((v) => v.name == 'q');
      expect(parameter.kind, VariableKind.parameter);
      expect(parameter.direction, ParameterDirection.inputOutput);
    });
  });

  group('scopes and control flow', () {
    test('a for header declares into a scope the body shares', () {
      final analysis = analyzeMain('''
  float sum = 0.0;
  for (int i = 0; i < 4; i++) {
    sum += float(i);
  }
''');
      final loop = statement(analysis, 'for (');
      expect(loop.kind, StatementKind.control);
      expect(names(loop.writes), ['i']);
      expect(loop.defaultPick, isNull, reason: 'i is gone after the loop');
      final body = statement(analysis, 'sum +=');
      expect(names(body.inScope), ['i', 'sum', 'fragColor']);
      expect(body.defaultPick?.name, 'sum');
    });

    test('if / else if / else, braced or not', () {
      final analysis = analyzeMain('''
  float x = 0.0;
  if (x > 1.0) x = 1.0;
  else if (x < 0.0) {
    float y = -x;
    x = y;
  } else
    x *= 2.0;
''');
      expect(analysis.statements.map((s) => s.span.text.split('\n').first), [
        'float x = 0.0;',
        'if (x > 1.0) x = 1.0;',
        'x = 1.0;',
        'if (x < 0.0) {',
        'float y = -x;',
        'x = y;',
        'x *= 2.0;',
      ]);
      final inner = statement(analysis, 'x = y;');
      expect(names(inner.inScope), ['y', 'x', 'fragColor']);
      // An un-braced body still gets its own scope.
      expect(statement(analysis, 'x = 1.0;').scope.kind, ScopeKind.block);
    });

    test('switch, loops and jumps', () {
      final analysis = analyzeMain('''
  int n = 2;
  switch (n) {
    case 1:
      n = 3;
      break;
    default:
      n = 4;
  }
  while (n > 0) n--;
  do { n++; } while (n < 2);
  if (n == 7) discard;
  for (;;) { continue; }
  return;
''');
      final kinds = {
        for (final s in analysis.statements)
          s.span.text.split('\n').first: s.kind,
      };
      expect(kinds['switch (n) {'], StatementKind.control);
      expect(kinds['n = 3;'], StatementKind.expression);
      expect(kinds['break;'], StatementKind.jump);
      expect(kinds['while (n > 0) n--;'], StatementKind.control);
      expect(kinds['n--;'], StatementKind.expression);
      expect(kinds['do { n++; } while (n < 2);'], StatementKind.control);
      expect(kinds['discard;'], StatementKind.jump);
      expect(kinds['continue;'], StatementKind.jump);
      expect(kinds['return;'], StatementKind.jump);
      expect(kinds.keys, isNot(contains('case 1:')));
    });
  });

  group('types', () {
    test('structs, arrays and constant array sizes', () {
      final analysis = analyzeMain(
        '''
  Light l = Light(vec3(1.0), 2.0);
  float w[N * 2];
  float v[M];
  Light lights[N];
''',
        globals: '''
struct Light {
  vec3 color;
  float radius;
};
const int N = 3;
''',
      );
      final light = variable(analysis, 'l').type as StructType;
      expect(light.name, 'Light');
      expect(light.fields.map((f) => '$f'), ['vec3 color', 'float radius']);
      expect(
        variable(analysis, 'w').type,
        const ArrayType(GlslType.floatType, 6),
      );
      expect(variable(analysis, 'lights').type.name, 'Light[3]');
      expect(analysis.diagnostics, isEmpty);
      expect(
        (variable(analysis, 'v').type as ArrayType).length,
        isNull,
        reason: 'M is not a known constant',
      );
    });

    test('a definition completes its prototype', () {
      final analysis = analyzeShader('''
vec3 shade(vec2 uv);
out vec4 fragColor;
void main() { fragColor = vec4(shade(vec2(0.5)), 1.0); }
vec3 shade(vec2 uv) { return vec3(uv, 0.0); }
''');
      final shades = analysis.symbols.functions.where((f) => f.name == 'shade');
      expect(shades, hasLength(1));
      expect(shades.single.isDefined, isTrue);
      expect(shades.single.parameters.single.type, GlslType.vec2);
    });
  });

  group('macros and includes', () {
    test('statements made by a macro cannot be picked; using one is fine', () {
      final analysis = analyzeMain(
        '''
  float x = SAT(0.5);
  RESET(x)
''',
        globals: '''
#define SAT(v) clamp(v, 0.0, 1.0)
#define RESET(v) v = 0.0;
''',
      );
      expect(statement(analysis, 'float x').isPickable, isTrue);
      final reset = statement(analysis, 'RESET(x)');
      expect(reset.isPickable, isFalse);
      expect(reset.unsupportedReason, contains('macro'));
      expect(names(reset.writes), ['x']);
    });

    test('declarations from an include are known; its statements are not listed', () {
      final analysis = analyzeShader(
        '''
#include "lib/noise.glsl"
out vec4 fragColor;
void main() {
  float n = noise(vec2(1.0));
  fragColor = vec4(n);
}
''',
        resolveInclude: (path) => path == 'lib/noise.glsl'
            ? 'float noise(vec2 p) {\n  float h = fract(p.x);\n  return h;\n}\n'
            : null,
      );
      expect(analysis.diagnostics, isEmpty);
      final noise = analysis.symbols.functions.first;
      expect(noise.name, 'noise');
      expect(noise.span, isNull, reason: 'not written in this file');
      expect(analysis.statements.map((s) => s.span.text), [
        'float n = noise(vec2(1.0));',
        'fragColor = vec4(n);',
      ]);
    });
  });

  group('problems', () {
    test('a syntax error disables one statement, not the file', () {
      final analysis = analyzeMain('''
  float a = ;
  float b = 2.0;
''');
      expect(analysis.diagnostics.single.severity, DiagnosticSeverity.error);
      expect(
        analysis.diagnostics.single.message,
        'Expected an expression, found ";".',
      );
      expect(statement(analysis, 'float a').isPickable, isFalse);
      expect(statement(analysis, 'float b').defaultPick?.name, 'b');
    });

    test('unknown types and interface blocks are reported', () {
      final analysis = analyzeMain(
        '  Foo f;\n',
        globals: 'uniform Params { float k; } params;\n',
      );
      expect(analysis.diagnostics.map((d) => d.message), [
        'Interface blocks are not supported in Flutter shaders.',
        'Unknown type "Foo".',
      ]);
    });

    test('never throws, whatever it is given', () {
      for (final source in [
        '',
        '}}}{{{ ((( ;;;',
        'void main() {',
        'float f(',
        '#if\n#else\n#else',
        'struct { } ;',
        'void main() { for (;; }',
      ]) {
        expect(() => analyzeShader(source), returnsNormally, reason: source);
      }
      expect(analyzeShader('').mainFunction, isNull);
    });
  });

  test('spans cover statements across lines', () {
    final analysis = analyzeMain('''
  float v = max(
    0.0,
    1.0
  );
''');
    expect(
      statement(analysis, 'float v').span.text,
      'float v = max(\n    0.0,\n    1.0\n  );',
    );
    expect(statement(analysis, 'float v').line, 5);
  });
}
