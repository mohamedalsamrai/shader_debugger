import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

void main() {
  group('fromKeyword', () {
    test('returns one canonical instance per built-in keyword', () {
      const keywords = [
        'void', 'bool', 'int', 'uint', 'float', //
        'vec2', 'vec3', 'vec4', 'ivec2', 'ivec3', 'ivec4', //
        'uvec2', 'uvec3', 'uvec4', 'bvec2', 'bvec3', 'bvec4', //
        'mat2', 'mat3', 'mat4', 'mat2x3', 'mat2x4', //
        'mat3x2', 'mat3x4', 'mat4x2', 'mat4x3', 'sampler2D',
      ];
      for (final keyword in keywords) {
        final type = GlslType.fromKeyword(keyword);
        expect(type?.name, keyword);
        expect(GlslType.fromKeyword(keyword), same(type), reason: keyword);
      }
    });

    test('treats matNxN as an alias of matN', () {
      expect(GlslType.fromKeyword('mat2x2'), same(GlslType.mat2));
      expect(GlslType.fromKeyword('mat3x3'), same(GlslType.mat3));
      expect(GlslType.fromKeyword('mat4x4'), same(GlslType.mat4));
    });

    test('returns null for struct names and types outside the subset', () {
      expect(GlslType.fromKeyword('Light'), isNull);
      expect(GlslType.fromKeyword('double'), isNull);
      expect(GlslType.fromKeyword('sampler3D'), isNull);
    });
  });

  group('of constructors', () {
    test('return the canonical instances', () {
      expect(ScalarType.of(ScalarKind.float), same(GlslType.floatType));
      expect(VectorType.of(ScalarKind.signedInt, 3), same(GlslType.ivec3));
      expect(MatrixType.of(3, 3), same(GlslType.mat3));
      expect(MatrixType.of(2, 4), same(GlslType.mat2x4));
    });

    test('reject sizes GLSL does not have', () {
      expect(() => VectorType.of(ScalarKind.float, 1), throwsRangeError);
      expect(() => VectorType.of(ScalarKind.float, 5), throwsRangeError);
      expect(() => MatrixType.of(1, 2), throwsRangeError);
    });
  });

  group('visualization', () {
    test('scalars are one channel; int and bool too, after a cast', () {
      for (final type in [
        GlslType.floatType,
        GlslType.intType,
        GlslType.boolType,
      ]) {
        expect(type.visualization, Visualization.scalar, reason: '$type');
        expect(type.selectorKind, isNull, reason: '$type');
      }
    });

    test('vectors are RG, RGB or RGBA', () {
      expect(GlslType.vec2.visualization, Visualization.rg);
      expect(GlslType.vec3.visualization, Visualization.rgb);
      expect(GlslType.vec4.visualization, Visualization.rgba);
      expect(GlslType.ivec3.visualization, Visualization.rgb);
      expect(GlslType.vec3.selectorKind, isNull);
    });

    test('a matrix needs a column, an array an element, a struct a field', () {
      final light = StructType('Light', const [
        StructField('radius', GlslType.floatType),
      ]);
      expect(GlslType.mat3.visualization, isNull);
      expect(GlslType.mat3.selectorKind, SelectorKind.column);
      expect(const ArrayType(GlslType.floatType, 4).visualization, isNull);
      expect(
        const ArrayType(GlslType.floatType, 4).selectorKind,
        SelectorKind.element,
      );
      expect(light.visualization, isNull);
      expect(light.selectorKind, SelectorKind.field);
    });

    test('void and samplers cannot be captured', () {
      for (final type in [GlslType.voidType, GlslType.sampler2D]) {
        expect(type.visualization, isNull, reason: '$type');
        expect(type.selectorKind, isNull, reason: '$type');
      }
    });
  });

  group('widenToVec4', () {
    test('matches the documented example for a float', () {
      expect(GlslType.floatType.widenToVec4('d'), 'vec4(d, 0.0, 0.0, 1.0)');
    });

    test('casts int, uint and bool scalars to float', () {
      expect(
        GlslType.intType.widenToVec4('i'),
        'vec4(float(i), 0.0, 0.0, 1.0)',
      );
      expect(
        GlslType.uintType.widenToVec4('u'),
        'vec4(float(u), 0.0, 0.0, 1.0)',
      );
      expect(
        GlslType.boolType.widenToVec4('b'),
        'vec4(float(b), 0.0, 0.0, 1.0)',
      );
    });

    test('pads float vectors with zeros and an alpha of 1', () {
      expect(GlslType.vec2.widenToVec4('uv'), 'vec4(uv, 0.0, 1.0)');
      expect(GlslType.vec3.widenToVec4('col'), 'vec4(col, 1.0)');
      expect(GlslType.vec4.widenToVec4('c'), 'c');
    });

    test('converts integer and boolean vectors to float vectors', () {
      expect(GlslType.ivec2.widenToVec4('p'), 'vec4(vec2(p), 0.0, 1.0)');
      expect(GlslType.bvec3.widenToVec4('m'), 'vec4(vec3(m), 1.0)');
      expect(GlslType.uvec4.widenToVec4('u'), 'vec4(u)');
    });

    test('throws for types the probe cannot draw directly', () {
      expect(() => GlslType.mat3.widenToVec4('m'), throwsUnsupportedError);
      expect(() => GlslType.sampler2D.widenToVec4('s'), throwsUnsupportedError);
      expect(() => GlslType.voidType.widenToVec4('v'), throwsUnsupportedError);
    });
  });

  group('select', () {
    final light = StructType('Light', const [
      StructField('position', GlslType.vec3),
      StructField('color', GlslType.vec4),
    ]);

    test('picks matrix columns', () {
      expect(GlslType.mat3.select(const IndexSelector(2)), GlslType.vec3);
      // mat2x3 has 2 columns of 3 rows.
      expect(GlslType.mat2x3.select(const IndexSelector(1)), GlslType.vec3);
      expect(GlslType.mat2x3.select(const IndexSelector(2)), isNull);
      expect(GlslType.mat3.select(const FieldSelector('x')), isNull);
    });

    test('picks array elements, any index when the length is unknown', () {
      const sized = ArrayType(GlslType.floatType, 4);
      expect(sized.select(const IndexSelector(3)), GlslType.floatType);
      expect(sized.select(const IndexSelector(4)), isNull);
      expect(
        const ArrayType(GlslType.vec2).select(const IndexSelector(99)),
        GlslType.vec2,
      );
    });

    test('picks struct fields', () {
      expect(light.select(const FieldSelector('color')), GlslType.vec4);
      expect(light.select(const FieldSelector('radius')), isNull);
      expect(light.select(const IndexSelector(0)), isNull);
    });

    test('picks vector components', () {
      expect(GlslType.vec3.select(const IndexSelector(2)), GlslType.floatType);
      expect(GlslType.bvec2.select(const IndexSelector(1)), GlslType.boolType);
      expect(GlslType.vec3.select(const IndexSelector(3)), isNull);
    });

    test('follows a path and builds the matching expression', () {
      final lights = ArrayType(light, 2);
      const path = [IndexSelector(1), FieldSelector('color')];
      expect(lights.selectPath(path), GlslType.vec4);
      expect(
        path.fold('uLights', (expression, s) => s.applyTo(expression)),
        'uLights[1].color',
      );
      expect(lights.selectPath(const [FieldSelector('color')]), isNull);
      expect(lights.selectPath(const []), same(lights));
    });
  });

  group('picker paths', () {
    final withSampler = StructType('Tex', const [
      StructField('image', GlslType.sampler2D),
      StructField('scale', GlslType.vec2),
    ]);
    final onlySampler = StructType('Only', const [
      StructField('image', GlslType.sampler2D),
    ]);

    test('drawable types need no step; samplers and void lead nowhere', () {
      expect(GlslType.floatType.firstDrawablePath, isEmpty);
      expect(GlslType.ivec3.firstDrawablePath, isEmpty);
      expect(GlslType.sampler2D.firstDrawablePath, isNull);
      expect(GlslType.voidType.firstDrawablePath, isNull);
    });

    test('composites start at their first drawable part', () {
      expect(GlslType.mat3.firstDrawablePath, [const IndexSelector(0)]);
      expect(ArrayType(withSampler, 3).firstDrawablePath, [
        const IndexSelector(0),
        const FieldSelector('scale'),
      ]);
      expect(const ArrayType(GlslType.mat2).firstDrawablePath, [
        const IndexSelector(0),
        const IndexSelector(0),
      ]);
      expect(onlySampler.firstDrawablePath, isNull);
      expect(ArrayType(onlySampler, 2).firstDrawablePath, isNull);
      expect(const ArrayType(GlslType.sampler2D, 2).firstDrawablePath, isNull);
    });

    test('every first path leads to a drawable type', () {
      for (final type in [
        GlslType.mat4x2,
        ArrayType(withSampler, 3),
        const ArrayType(ArrayType(GlslType.mat2, 2), 2),
      ]) {
        expect(
          type.selectPath(type.firstDrawablePath!)?.visualization,
          isNotNull,
          reason: '$type',
        );
      }
    });

    test('choices list each column, element or drawable field', () {
      expect(GlslType.mat3x2.selectorChoices, const [
        IndexSelector(0),
        IndexSelector(1),
        IndexSelector(2),
      ]);
      expect(const ArrayType(GlslType.floatType, 2).selectorChoices, const [
        IndexSelector(0),
        IndexSelector(1),
      ]);
      expect(withSampler.selectorChoices, const [FieldSelector('scale')]);
    });

    test('no choices without a composite, or without a known length', () {
      expect(GlslType.vec3.selectorChoices, isEmpty);
      expect(GlslType.sampler2D.selectorChoices, isEmpty);
      expect(const ArrayType(GlslType.floatType).selectorChoices, isEmpty);
      expect(const ArrayType(GlslType.sampler2D, 2).selectorChoices, isEmpty);
    });
  });

  group('names and equality', () {
    test('array names list the outermost dimension first', () {
      expect(const ArrayType(GlslType.vec2, 3).name, 'vec2[3]');
      expect(
        const ArrayType(ArrayType(GlslType.floatType, 3), 2).name,
        'float[2][3]',
      );
      expect(const ArrayType(GlslType.floatType).name, 'float[]');
    });

    test('array types compare by element type and length', () {
      // Built at runtime, so these are not canonicalized const instances.
      final length = int.parse('3');
      expect(
        ArrayType(GlslType.vec2, length),
        const ArrayType(GlslType.vec2, 3),
      );
      expect(
        ArrayType(GlslType.vec2, length).hashCode,
        const ArrayType(GlslType.vec2, 3).hashCode,
      );
      expect(
        ArrayType(GlslType.vec2, length),
        isNot(const ArrayType(GlslType.vec2, 4)),
      );
      expect(
        ArrayType(GlslType.vec2, length),
        isNot(const ArrayType(GlslType.vec3, 3)),
      );
    });

    test('struct types compare by identity', () {
      const fields = [StructField('x', GlslType.floatType)];
      expect(StructType('S', fields), isNot(StructType('S', fields)));
    });

    test('non-square matrices use the CxR spelling', () {
      expect(GlslType.mat3x2.name, 'mat3x2');
      expect(GlslType.mat3x2.columnType, GlslType.vec2);
    });
  });
}
