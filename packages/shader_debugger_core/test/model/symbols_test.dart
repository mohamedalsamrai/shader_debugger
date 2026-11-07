import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

void main() {
  late SymbolTable table;
  late Scope global;

  setUp(() {
    table = SymbolTable();
    global = table.global;
  });

  test('assigns ids in declaration order', () {
    final uA = global.declareVariable('uA', GlslType.vec4, kind: VariableKind.uniform);
    final main = global.declareFunction('main', GlslType.voidType);
    final x = global
        .openFunction(main)
        .declareVariable('x', GlslType.floatType, kind: VariableKind.local);

    expect([uA.id, main.id, x.id], [0, 1, 2]);
    expect(table.symbols, [uA, main, x]);
    expect(table.symbolById(2), same(x));
    expect(table.symbolById(3), isNull);
    expect(table.symbolById(-1), isNull);
  });

  test('links a function, its scope and nested blocks', () {
    final main = global.declareFunction('main', GlslType.voidType);
    expect(main.isDefined, isFalse);

    final body = global.openFunction(main);
    final block = body.openBlock();

    expect(main.body, same(body));
    expect(main.isDefined, isTrue);
    expect(main.isMain, isTrue);
    expect(body.function, same(main));
    expect(block.function, same(main));
    expect([global.depth, body.depth, block.depth], [0, 1, 2]);
    expect(global.children, [body]);
    expect(body.children, [block]);
    expect(block.parent, same(body));
  });

  test('isMain needs void main() exactly', () {
    final withParam = global.declareFunction(
      'main',
      GlslType.voidType,
      parameters: const [FunctionParameter(GlslType.floatType)],
    );
    final returnsFloat = global.declareFunction('main', GlslType.floatType);
    expect(withParam.isMain, isFalse);
    expect(returnsFloat.isMain, isFalse);
  });

  test('lists uniforms and functions in declaration order', () {
    global.declareVariable('uSize', GlslType.vec2, kind: VariableKind.uniform);
    global.declareVariable('fragColor', GlslType.vec4, kind: VariableKind.output);
    global.declareVariable('uImage', GlslType.sampler2D, kind: VariableKind.uniform);
    final helper = global.declareFunction('helper', GlslType.floatType);
    final main = global.declareFunction('main', GlslType.voidType);

    expect(table.uniforms.map((u) => u.name), ['uSize', 'uImage']);
    expect(table.functions, [helper, main]);
  });

  group('lookup', () {
    test('finds the nearest declaration; inner ones hide outer ones', () {
      final outer = global.declareVariable('x', GlslType.floatType, kind: VariableKind.global);
      final body = global.openFunction(global.declareFunction('main', GlslType.voidType));
      final block = body.openBlock();
      final inner = block.declareVariable('x', GlslType.vec2, kind: VariableKind.local);

      expect(block.lookup('x'), same(inner));
      expect(body.lookup('x'), same(outer));
      expect(block.lookup('y'), isNull);
    });

    test('a variable is visible only after its declarator', () {
      // float x = 1.0;                  outer x visible from offset 13
      // void main() {
      //   float x = x + 1.0;            inner x visible from offset 60
      // }
      final outer = global.declareVariable(
        'x',
        GlslType.floatType,
        kind: VariableKind.global,
        visibleFrom: 13,
      );
      final body = global.openFunction(
        global.declareFunction('main', GlslType.voidType, visibleFrom: 25),
      );
      final inner = body.declareVariable(
        'x',
        GlslType.floatType,
        kind: VariableKind.local,
        visibleFrom: 60,
      );

      expect(body.lookup('x', at: 55), same(outer), reason: 'inside the initializer');
      expect(body.lookup('x', at: 60), same(inner));
      expect(body.lookup('x', at: 5), isNull, reason: 'before both declarations');
      expect(body.lookup('x'), same(inner), reason: 'no offset: end of scope');
    });

    test('defaults visibility to the end of the declared name', () {
      final file = SourceFile.fromString('uniform vec2 uSize;');
      final uSize = global.declareVariable(
        'uSize',
        GlslType.vec2,
        kind: VariableKind.uniform,
        span: file.span(13, 18),
      );

      expect(uSize.visibleFrom, 18);
      expect(global.lookup('uSize', at: 17), isNull);
      expect(global.lookup('uSize', at: 18), same(uSize));
    });

    test('does not see a global declared after the point of use', () {
      final main = global.declareFunction('main', GlslType.voidType, visibleFrom: 10);
      final body = global.openFunction(main);
      global.declareVariable('late', GlslType.floatType, kind: VariableKind.global, visibleFrom: 200);

      expect(body.lookup('late', at: 50), isNull);
      expect(body.lookup('late', at: 250), isNotNull);
    });
  });

  group('lookupFunctions', () {
    test('returns every visible overload', () {
      final f1 = global.declareFunction(
        'shade',
        GlslType.floatType,
        parameters: const [FunctionParameter(GlslType.floatType, name: 'x')],
      );
      final f2 = global.declareFunction(
        'shade',
        GlslType.vec2,
        parameters: const [FunctionParameter(GlslType.vec2, name: 'x')],
      );
      expect(global.lookupFunctions('shade'), [f1, f2]);
      expect(global.lookupFunctions('missing'), isEmpty);
    });

    test('returns nothing when a nearer variable hides the function', () {
      global.declareFunction('shade', GlslType.floatType);
      final body = global.openFunction(global.declareFunction('main', GlslType.voidType));
      body.declareVariable('shade', GlslType.floatType, kind: VariableKind.local);

      expect(body.lookupFunctions('shade'), isEmpty);
      expect(global.lookupFunctions('shade'), hasLength(1));
    });
  });

  group('visibleVariables', () {
    test('lists the innermost scope first and drops hidden variables', () {
      final uSize = global.declareVariable('uSize', GlslType.vec2, kind: VariableKind.uniform, visibleFrom: 0);
      global.declareVariable('t', GlslType.floatType, kind: VariableKind.global, visibleFrom: 0);
      final main = global.declareFunction('main', GlslType.voidType, visibleFrom: 0);
      final body = global.openFunction(main);
      final uv = body.declareVariable('uv', GlslType.vec2, kind: VariableKind.local, visibleFrom: 10);
      final block = body.openBlock();
      final t = block.declareVariable('t', GlslType.intType, kind: VariableKind.local, visibleFrom: 20);
      final later = block.declareVariable('later', GlslType.floatType, kind: VariableKind.local, visibleFrom: 40);

      expect(block.visibleVariables(at: 30), [t, uv, uSize]);
      expect(block.visibleVariables(), [t, later, uv, uSize]);
    });

    test('a nearer struct or function name also hides an outer variable', () {
      global.declareVariable('Light', GlslType.floatType, kind: VariableKind.global);
      final body = global.openFunction(global.declareFunction('main', GlslType.voidType));
      body.declareStruct(StructType('Light', const []));

      expect(body.visibleVariables(), isEmpty);
    });
  });

  group('declaration rules', () {
    test('uniforms, outputs and globals belong to the global scope', () {
      final body = global.openFunction(global.declareFunction('main', GlslType.voidType));
      for (final kind in [VariableKind.uniform, VariableKind.output, VariableKind.global]) {
        expect(() => body.declareVariable('v', GlslType.floatType, kind: kind), throwsStateError);
        expect(kind.isGlobal, isTrue);
      }
    });

    test('parameters belong to a function scope, locals to functions and blocks', () {
      final body = global.openFunction(global.declareFunction('main', GlslType.voidType));
      final block = body.openBlock();
      expect(() => global.declareVariable('p', GlslType.floatType, kind: VariableKind.parameter), throwsStateError);
      expect(() => block.declareVariable('p', GlslType.floatType, kind: VariableKind.parameter), throwsStateError);
      expect(() => global.declareVariable('l', GlslType.floatType, kind: VariableKind.local), throwsStateError);
      expect(block.declareVariable('l', GlslType.floatType, kind: VariableKind.local).kind, VariableKind.local);
    });

    test('parameters default to in; other variables take no direction', () {
      final body = global.openFunction(global.declareFunction('f', GlslType.voidType));
      final p = body.declareVariable('p', GlslType.floatType, kind: VariableKind.parameter);
      final q = body.declareVariable(
        'q',
        GlslType.floatType,
        kind: VariableKind.parameter,
        direction: ParameterDirection.output,
      );

      expect(p.direction, ParameterDirection.input);
      expect(q.direction?.writesArgument, isTrue);
      expect(body.declareVariable('l', GlslType.floatType, kind: VariableKind.local).direction, isNull);
      expect(
        () => body.declareVariable(
          'r',
          GlslType.floatType,
          kind: VariableKind.local,
          direction: ParameterDirection.output,
        ),
        throwsArgumentError,
      );
    });

    test('functions are declared and defined only at global scope, once', () {
      final main = global.declareFunction('main', GlslType.voidType);
      final body = global.openFunction(main);
      expect(() => global.openBlock(), throwsStateError);
      expect(() => body.declareFunction('g', GlslType.voidType), throwsStateError);
      expect(() => body.openFunction(main), throwsStateError);
      expect(() => global.openFunction(main), throwsStateError);
      expect(() => SymbolTable().global.openFunction(main), throwsArgumentError);
    });
  });

  test('describes signatures readably', () {
    final f = global.declareFunction(
      'f',
      GlslType.floatType,
      parameters: const [
        FunctionParameter(GlslType.vec2, name: 'uv'),
        FunctionParameter(GlslType.floatType, name: 'd', direction: ParameterDirection.inputOutput),
        FunctionParameter(GlslType.vec3, isConst: true),
      ],
    );
    expect(f.toString(), 'float f(vec2 uv, inout float d, const vec3) #0');
  });
}
