/// GLSL types as the debugger sees them.
///
/// The model covers what Flutter fragment shaders use: scalars, vectors,
/// matrices, `sampler2D`, arrays and structs. Besides naming types, it answers
/// the questions from design doc §5 ("Type → visualization"): can the probe
/// draw a value of this type directly, and if not, what must the picker ask
/// for first?
library;

/// The component kind shared by a scalar type and the vectors built from it.
enum ScalarKind {
  /// `bool` and `bvec2`–`bvec4`.
  boolean('bool', 'bvec'),

  /// `int` and `ivec2`–`ivec4`.
  signedInt('int', 'ivec'),

  /// `uint` and `uvec2`–`uvec4`.
  unsignedInt('uint', 'uvec'),

  /// `float` and `vec2`–`vec4`.
  float('float', 'vec');

  const ScalarKind(this.keyword, this.vectorPrefix);

  /// The scalar type's keyword, such as `int`.
  final String keyword;

  /// The prefix of this kind's vector types, such as `ivec`.
  final String vectorPrefix;
}

/// How the probe draws a value it can capture directly.
enum Visualization {
  /// One component, drawn in grayscale or through a colormap. `int`, `uint`
  /// and `bool` values are cast to `float` first.
  scalar(1),

  /// Two components, drawn as red and green.
  rg(2),

  /// Three components, drawn as RGB.
  rgb(3),

  /// Four components, drawn as RGBA.
  rgba(4);

  const Visualization(this.componentCount);

  /// How many components of the captured `vec4` carry the value.
  final int componentCount;
}

/// What the picker must ask for before it can capture a composite value.
enum SelectorKind {
  /// A matrix column, chosen with an [IndexSelector] (`m[1]`).
  column,

  /// An array element, chosen with an [IndexSelector] (`a[2]`).
  element,

  /// A struct field, chosen with a [FieldSelector] (`light.color`).
  field,
}

/// One step from a composite value towards a part the probe can draw.
sealed class Selector {
  const Selector();

  /// Returns the GLSL expression for this part of [expression].
  ///
  /// [expression] must be a postfix expression, such as a variable name or
  /// the result of an earlier [applyTo].
  String applyTo(String expression);
}

/// Selects a matrix column, an array element or a vector component.
final class IndexSelector extends Selector {
  const IndexSelector(this.index) : assert(index >= 0, 'index is negative');

  /// The zero-based column, element or component.
  final int index;

  @override
  String applyTo(String expression) => '$expression[$index]';

  @override
  bool operator ==(Object other) =>
      other is IndexSelector && other.index == index;

  @override
  int get hashCode => Object.hash(IndexSelector, index);

  @override
  String toString() => '[$index]';
}

/// Selects a struct field.
final class FieldSelector extends Selector {
  const FieldSelector(this.name);

  /// The field's name.
  final String name;

  @override
  String applyTo(String expression) => '$expression.$name';

  @override
  bool operator ==(Object other) =>
      other is FieldSelector && other.name == name;

  @override
  int get hashCode => Object.hash(FieldSelector, name);

  @override
  String toString() => '.$name';
}

/// A GLSL type.
///
/// Built-in types are canonical: [fromKeyword], [ScalarType.of],
/// [VectorType.of] and [MatrixType.of] always return the same instance, so
/// `==` on them is identity. Array types compare by element type and length.
/// Struct types compare by identity, because GLSL struct types are nominal.
sealed class GlslType {
  const GlslType();

  static const VoidType voidType = VoidType._();

  static const ScalarType boolType = ScalarType._(ScalarKind.boolean);
  static const ScalarType intType = ScalarType._(ScalarKind.signedInt);
  static const ScalarType uintType = ScalarType._(ScalarKind.unsignedInt);
  static const ScalarType floatType = ScalarType._(ScalarKind.float);

  static const VectorType vec2 = VectorType._(ScalarKind.float, 2);
  static const VectorType vec3 = VectorType._(ScalarKind.float, 3);
  static const VectorType vec4 = VectorType._(ScalarKind.float, 4);
  static const VectorType ivec2 = VectorType._(ScalarKind.signedInt, 2);
  static const VectorType ivec3 = VectorType._(ScalarKind.signedInt, 3);
  static const VectorType ivec4 = VectorType._(ScalarKind.signedInt, 4);
  static const VectorType uvec2 = VectorType._(ScalarKind.unsignedInt, 2);
  static const VectorType uvec3 = VectorType._(ScalarKind.unsignedInt, 3);
  static const VectorType uvec4 = VectorType._(ScalarKind.unsignedInt, 4);
  static const VectorType bvec2 = VectorType._(ScalarKind.boolean, 2);
  static const VectorType bvec3 = VectorType._(ScalarKind.boolean, 3);
  static const VectorType bvec4 = VectorType._(ScalarKind.boolean, 4);

  static const MatrixType mat2 = MatrixType._(2, 2);
  static const MatrixType mat3 = MatrixType._(3, 3);
  static const MatrixType mat4 = MatrixType._(4, 4);
  static const MatrixType mat2x3 = MatrixType._(2, 3);
  static const MatrixType mat2x4 = MatrixType._(2, 4);
  static const MatrixType mat3x2 = MatrixType._(3, 2);
  static const MatrixType mat3x4 = MatrixType._(3, 4);
  static const MatrixType mat4x2 = MatrixType._(4, 2);
  static const MatrixType mat4x3 = MatrixType._(4, 3);

  /// The only sampler type Flutter fragment shaders support.
  static const SamplerType sampler2D = SamplerType._('sampler2D');

  static const List<GlslType> _builtIns = [
    voidType, boolType, intType, uintType, floatType, //
    vec2, vec3, vec4, ivec2, ivec3, ivec4, //
    uvec2, uvec3, uvec4, bvec2, bvec3, bvec4, //
    mat2, mat3, mat4, mat2x3, mat2x4, mat3x2, mat3x4, mat4x2, mat4x3, //
    sampler2D,
  ];

  static final Map<String, GlslType> _byKeyword = {
    for (final type in _builtIns) type.name: type,
    'mat2x2': mat2,
    'mat3x3': mat3,
    'mat4x4': mat4,
  };

  /// The built-in type spelled [keyword], such as `vec3` or `mat2x3`, or null
  /// if [keyword] does not name one.
  ///
  /// Struct names are not keywords; look them up in a `Scope`.
  static GlslType? fromKeyword(String keyword) => _byKeyword[keyword];

  /// The type as GLSL spells it, such as `vec3`, `float[4]` or `Light`.
  String get name;

  /// How the probe draws a value of this type, or null if it cannot capture
  /// one directly.
  ///
  /// Composite types need a [Selector] first (see [selectorKind]); `void` and
  /// samplers cannot be captured at all.
  Visualization? get visualization => null;

  /// The kind of [Selector] the picker asks for to narrow a value of this
  /// type, or null if the type is not a composite.
  SelectorKind? get selectorKind => null;

  /// The type of the part of a value that [selector] picks, or null if
  /// [selector] does not apply: wrong kind, index out of range, or a field
  /// the struct does not have.
  GlslType? select(Selector selector) => null;

  /// Applies [path] in order. Returns null as soon as a step does not apply.
  GlslType? selectPath(Iterable<Selector> path) {
    GlslType type = this;
    for (final selector in path) {
      final next = type.select(selector);
      if (next == null) return null;
      type = next;
    }
    return type;
  }

  /// Returns a GLSL expression that converts [expression], a value of this
  /// type, to the `vec4` the probe writes out.
  ///
  /// Missing components become `0.0`, a missing alpha becomes `1.0`, and
  /// integer or boolean values are converted to float. For example, a `float`
  /// named `d` becomes `vec4(d, 0.0, 0.0, 1.0)`.
  ///
  /// Throws an [UnsupportedError] when [visualization] is null.
  String widenToVec4(String expression) =>
      throw UnsupportedError('A $name value cannot be captured directly.');

  @override
  String toString() => name;
}

/// `void`: the return type of a function that returns nothing.
final class VoidType extends GlslType {
  const VoidType._();

  @override
  String get name => 'void';
}

/// `bool`, `int`, `uint` or `float`.
final class ScalarType extends GlslType {
  const ScalarType._(this.kind);

  /// The scalar type of [kind].
  factory ScalarType.of(ScalarKind kind) =>
      GlslType.fromKeyword(kind.keyword) as ScalarType;

  final ScalarKind kind;

  @override
  String get name => kind.keyword;

  @override
  Visualization get visualization => Visualization.scalar;

  @override
  String widenToVec4(String expression) {
    final value = kind == ScalarKind.float ? expression : 'float($expression)';
    return 'vec4($value, 0.0, 0.0, 1.0)';
  }
}

/// A vector of 2 to 4 components, such as `vec3` or `ivec2`.
final class VectorType extends GlslType {
  const VectorType._(this.kind, this.size);

  /// The vector type with [size] components of [kind].
  ///
  /// Throws a [RangeError] unless [size] is between 2 and 4.
  factory VectorType.of(ScalarKind kind, int size) {
    RangeError.checkValueInInterval(size, 2, 4, 'size');
    return GlslType.fromKeyword('${kind.vectorPrefix}$size') as VectorType;
  }

  final ScalarKind kind;

  /// The number of components.
  final int size;

  /// The type of one component.
  ScalarType get componentType => ScalarType.of(kind);

  @override
  String get name => '${kind.vectorPrefix}$size';

  @override
  Visualization get visualization => switch (size) {
    2 => Visualization.rg,
    3 => Visualization.rgb,
    _ => Visualization.rgba,
  };

  /// Vectors are drawn whole, but an [IndexSelector] can still pick one
  /// component, as `v[1]` does in GLSL.
  @override
  GlslType? select(Selector selector) => switch (selector) {
    IndexSelector(:final index) when index < size => componentType,
    _ => null,
  };

  @override
  String widenToVec4(String expression) {
    final value = kind == ScalarKind.float
        ? expression
        : 'vec$size($expression)';
    return switch (size) {
      2 => 'vec4($value, 0.0, 1.0)',
      3 => 'vec4($value, 1.0)',
      _ => value,
    };
  }
}

/// A float matrix with 2 to 4 columns and rows, such as `mat3` or `mat2x3`.
///
/// GLSL matrices are column-major: `mat2x3` has 2 columns of type `vec3`.
final class MatrixType extends GlslType {
  const MatrixType._(this.columns, this.rows);

  /// The matrix type with [columns] columns and [rows] rows.
  ///
  /// Throws a [RangeError] unless both are between 2 and 4.
  factory MatrixType.of(int columns, int rows) {
    RangeError.checkValueInInterval(columns, 2, 4, 'columns');
    RangeError.checkValueInInterval(rows, 2, 4, 'rows');
    return GlslType.fromKeyword('mat${columns}x$rows') as MatrixType;
  }

  final int columns;
  final int rows;

  /// The type of one column.
  VectorType get columnType => VectorType.of(ScalarKind.float, rows);

  @override
  String get name => columns == rows ? 'mat$columns' : 'mat${columns}x$rows';

  @override
  SelectorKind get selectorKind => SelectorKind.column;

  @override
  GlslType? select(Selector selector) => switch (selector) {
    IndexSelector(:final index) when index < columns => columnType,
    _ => null,
  };
}

/// An opaque sampler type, such as `sampler2D`.
final class SamplerType extends GlslType {
  const SamplerType._(this.name);

  @override
  final String name;
}

/// An array type, such as `float[4]`.
final class ArrayType extends GlslType {
  const ArrayType(this.elementType, [this.length])
    : assert(length == null || length > 0, 'length must be positive');

  final GlslType elementType;

  /// The number of elements, or null if the size expression could not be
  /// evaluated (for example, it uses a constant the analyzer cannot fold).
  final int? length;

  /// Spelled the GLSL way, outermost dimension first: an array of 2 arrays of
  /// 3 floats is `float[2][3]`.
  @override
  String get name {
    final dimensions = StringBuffer();
    GlslType type = this;
    while (type is ArrayType) {
      dimensions.write('[${type.length ?? ''}]');
      type = type.elementType;
    }
    return '${type.name}$dimensions';
  }

  @override
  SelectorKind get selectorKind => SelectorKind.element;

  /// Picks an element. When [length] is unknown, every index is accepted.
  @override
  GlslType? select(Selector selector) {
    if (selector is! IndexSelector) return null;
    final length = this.length;
    return length == null || selector.index < length ? elementType : null;
  }

  @override
  bool operator ==(Object other) =>
      other is ArrayType &&
      other.elementType == elementType &&
      other.length == length;

  @override
  int get hashCode => Object.hash(ArrayType, elementType, length);
}

/// A struct type declared in the shader.
///
/// Struct types compare by identity: two declarations with the same fields are
/// still different types.
final class StructType extends GlslType {
  StructType(this.name, Iterable<StructField> fields)
    : fields = List.unmodifiable(fields);

  @override
  final String name;

  /// The fields, in declaration order.
  final List<StructField> fields;

  /// The field called [fieldName], or null if the struct has none.
  StructField? fieldNamed(String fieldName) =>
      fields.where((field) => field.name == fieldName).firstOrNull;

  @override
  SelectorKind get selectorKind => SelectorKind.field;

  @override
  GlslType? select(Selector selector) => switch (selector) {
    FieldSelector(name: final fieldName) => fieldNamed(fieldName)?.type,
    _ => null,
  };
}

/// A field of a [StructType].
final class StructField {
  const StructField(this.name, this.type);

  final String name;
  final GlslType type;

  @override
  String toString() => '$type $name';
}
