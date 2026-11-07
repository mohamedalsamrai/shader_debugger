import 'dart:io';

import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// The probe for "capture `d` in gradient.frag", stamp 1. The example app
/// registers this file as a shader, and its runtime tests draw it, so the
/// runtime is tested against real instrumenter output.
///
/// Regenerate with `UPDATE_GOLDENS=1 dart test test/instrument`.
const goldenProbePath =
    '../shader_debugger/example/test/probes/gradient_capture_d.frag';

void main() {
  group('the design doc example, capturing d', () {
    late GradientFixture f;
    late Probe probe;

    setUp(() {
      f = GradientFixture();
      probe = instrument(
        f.analysis,
        CaptureRequest(statement: f.dStatement, variable: f.d),
        stamp: 1,
      );
    });

    test('matches the golden probe used by the runtime tests', () {
      final golden = File(goldenProbePath);
      if (Platform.environment['UPDATE_GOLDENS'] == '1') {
        golden.writeAsStringSync(probe.source);
      }
      expect(probe.source, golden.readAsStringSync());
    });

    test('describes the captured value', () {
      expect(probe.valueType, GlslType.floatType);
      expect(probe.visualization, Visualization.scalar);
      expect(probe.stamp, 1);
      expect(probe.stampUniform, '_dbg_stamp_1');
      expect(probe.request.expression, 'd');
    });

    test('copies the value into _dbg_value right after the statement', () {
      expect(
        probe.source,
        contains(
          'float d = length(uv - 0.5); _dbg_value = vec4(d, 0.0, 0.0, 1.0);',
        ),
      );
    });

    test('renames main and adds a main that encodes the value', () {
      expect(probe.source, contains('void _dbg_main() {'));
      expect(
        probe.source,
        contains(
          'void main() {\n  _dbg_main();\n  fragColor = _dbg_encode(_dbg_value);\n}',
        ),
      );
      expect(RegExp(r'void main\(').allMatches(probe.source), hasLength(1));
    });

    test('routes FlutterFragCoord through _dbg_fragCoord', () {
      expect(probe.source, contains('vec2 uv = _dbg_fragCoord().xy / uSize;'));
      // The only call left is the fallback inside _dbg_fragCoord.
      expect('FlutterFragCoord('.allMatches(probe.source), hasLength(1));
      expect(probe.source, contains('vec2 _dbg_fragCoord();'));
    });

    test('declares the debug uniforms after the user uniforms', () {
      final source = probe.source;
      expect(
        source.indexOf('uniform float _dbg_mode;'),
        greaterThan(source.indexOf('uniform vec4 uB;')),
      );
      expect(source, contains('uniform vec2 _dbg_range;'));
      expect(source, contains('uniform float _dbg_stamp_1;'));
    });

    test('keeps the declarations right after the runtime_effect include', () {
      expect(
        probe.source,
        startsWith(
          '#version 460 core\n\n#include <flutter/runtime_effect.glsl>\n\n'
          '// Shader Debugger probe',
        ),
      );
    });
  });

  group('capture placement', () {
    test('wraps an expression statement so the capture stays in its branch', () {
      final f = GradientFixture();
      final probe = instrument(
        f.analysis,
        CaptureRequest(statement: f.outputStatement, variable: f.fragColor),
        stamp: 2,
      );
      expect(
        probe.source,
        contains('{ fragColor = vec4(col, 1.0); _dbg_value = fragColor; }'),
      );
      expect(probe.visualization, Visualization.rgba);
    });

    test('captures before a jump', () {
      final f = BranchyFixture();
      final probe = instrument(
        f.analysis,
        CaptureRequest(statement: f.returnStatement, variable: f.a),
        stamp: 3,
      );
      expect(
        probe.source,
        contains('{ _dbg_value = vec4(a, 0.0, 0.0, 1.0); return; }'),
      );
    });

    test('captures after a whole control statement', () {
      final f = BranchyFixture();
      final probe = instrument(
        f.analysis,
        CaptureRequest(statement: f.ifStatement, variable: f.a),
        stamp: 4,
      );
      expect(
        probe.source,
        contains(
          '{ if (a > 0.5) {\n'
          '    fragColor = vec4(a);\n'
          '    return;\n'
          '  } _dbg_value = vec4(a, 0.0, 0.0, 1.0); }',
        ),
      );
    });

    test('follows a selector path', () {
      final f = GradientFixture();
      final probe = instrument(
        f.analysis,
        CaptureRequest(
          statement: f.colStatement,
          variable: f.col,
          path: const [IndexSelector(1)],
        ),
        stamp: 5,
      );
      expect(probe.request.expression, 'col[1]');
      expect(probe.valueType, GlslType.floatType);
      expect(probe.source, contains('_dbg_value = vec4(col[1], 0.0, 0.0, 1.0);'));
    });

    test('draws vectors without the colormap', () {
      final f = GradientFixture();
      final probe = instrument(
        f.analysis,
        CaptureRequest(statement: f.colStatement, variable: f.col),
        stamp: 6,
      );
      expect(probe.visualization, Visualization.rgb);
      expect(probe.source, contains('_dbg_value = vec4(col, 1.0);'));
      expect(probe.source, isNot(contains('_dbg_colormap')));
    });
  });

  group('identifiers', () {
    const source = '''
#version 460 core
#include <flutter/runtime_effect.glsl>
out vec4 fragColor;
// Uses FlutterFragCoord() below.
/* FlutterFragCoord */
void main() {
  float x = FlutterFragCoord().x * 1.5e2;
  fragColor = vec4(x);
}
''';

    test('leaves comments alone and skips numbers', () {
      final b = AnalysisBuilder(source, 'comments.frag');
      b.declareFlutterFragCoord();
      final out = b.declare(
        b.table.global,
        'fragColor',
        GlslType.vec4,
        VariableKind.output,
        'out vec4 fragColor;',
      );
      final main = b.defineVoidFunction('main');
      final x = b.declare(
        main,
        'x',
        GlslType.floatType,
        VariableKind.local,
        'float x = FlutterFragCoord().x * 1.5e2;',
      );
      final statement = b.statement(
        StatementKind.declaration,
        'float x = FlutterFragCoord().x * 1.5e2;',
        main,
        writes: [x],
      );
      b.statement(
        StatementKind.expression,
        'fragColor = vec4(x);',
        main,
        writes: [out],
      );
      final probe = instrument(
        b.build(),
        CaptureRequest(statement: statement, variable: x),
        stamp: 0,
      );
      expect(probe.source, contains('// Uses FlutterFragCoord() below.'));
      expect(probe.source, contains('/* FlutterFragCoord */'));
      expect(probe.source, contains('float x = _dbg_fragCoord().x * 1.5e2;'));
    });

    test('a shader without FlutterFragCoord gets no _dbg_fragCoord', () {
      const plain = '''
#version 460 core
out vec4 color;
void main() {
  float v = 0.25;
  color = vec4(v);
}
''';
      final b = AnalysisBuilder(plain, 'plain.frag');
      b.declare(
        b.table.global,
        'color',
        GlslType.vec4,
        VariableKind.output,
        'out vec4 color;',
      );
      final main = b.defineVoidFunction('main');
      final v = b.declare(
        main,
        'v',
        GlslType.floatType,
        VariableKind.local,
        'float v = 0.25;',
      );
      final statement = b.statement(
        StatementKind.declaration,
        'float v = 0.25;',
        main,
        writes: [v],
      );
      final probe = instrument(
        b.build(),
        CaptureRequest(statement: statement, variable: v),
        stamp: 0,
      );
      expect(probe.source, isNot(contains('_dbg_fragCoord')));
      expect(
        probe.source,
        startsWith('#version 460 core\n\n// Shader Debugger probe'),
      );
      expect(probe.source, contains('  color = _dbg_encode(_dbg_value);'));
    });
  });

  group('rejects', () {
    late GradientFixture f;

    setUp(() => f = GradientFixture());

    test('a variable that is not in scope yet', () {
      expect(
        () => instrument(
          f.analysis,
          CaptureRequest(statement: f.dStatement, variable: f.col),
          stamp: 1,
        ),
        throwsA(isA<InstrumentationException>()),
      );
    });

    test('a value the probe cannot draw', () {
      expect(
        () => instrument(
          f.analysis,
          CaptureRequest(
            statement: f.colStatement,
            variable: f.col,
            path: const [IndexSelector(7)],
          ),
          stamp: 1,
        ),
        throwsA(isA<InstrumentationException>()),
      );
    });

    test('a statement from another analysis, or a negative stamp', () {
      final other = GradientFixture();
      expect(
        () => instrument(
          f.analysis,
          CaptureRequest(statement: other.dStatement, variable: other.d),
          stamp: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => instrument(
          f.analysis,
          CaptureRequest(statement: f.dStatement, variable: f.d),
          stamp: -1,
        ),
        throwsArgumentError,
      );
    });

    test('a statement the parser could not understand', () {
      final b = AnalysisBuilder(gradientSource, 'gradient.frag');
      b.declare(
        b.table.global,
        'fragColor',
        GlslType.vec4,
        VariableKind.output,
        'out vec4 fragColor;',
      );
      final main = b.defineVoidFunction('main');
      final uv = b.declare(
        main,
        'uv',
        GlslType.vec2,
        VariableKind.local,
        'vec2 uv = FlutterFragCoord().xy / uSize;',
      );
      final statement = b.statement(
        StatementKind.declaration,
        'vec2 uv = FlutterFragCoord().xy / uSize;',
        main,
        writes: [uv],
        unsupportedReason: 'comes from a macro expansion',
      );
      expect(
        () => instrument(
          b.build(),
          CaptureRequest(statement: statement, variable: uv),
          stamp: 1,
        ),
        throwsA(
          isA<InstrumentationException>().having(
            (e) => e.message,
            'message',
            contains('macro expansion'),
          ),
        ),
      );
    });

    test('a shader without an output', () {
      final b = AnalysisBuilder(gradientSource, 'gradient.frag');
      final main = b.defineVoidFunction('main');
      final uv = b.declare(
        main,
        'uv',
        GlslType.vec2,
        VariableKind.local,
        'vec2 uv = FlutterFragCoord().xy / uSize;',
      );
      final statement = b.statement(
        StatementKind.declaration,
        'vec2 uv = FlutterFragCoord().xy / uSize;',
        main,
        writes: [uv],
      );
      expect(
        () => instrument(
          b.build(),
          CaptureRequest(statement: statement, variable: uv),
          stamp: 1,
        ),
        throwsA(isA<InstrumentationException>()),
      );
    });
  });
}
