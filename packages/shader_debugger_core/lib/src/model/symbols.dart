/// The symbol table: scopes and the symbols declared in them ("The analyzer"
/// in docs/architecture.md).
///
/// Scopes nest global → function → block. Each declaration becomes a
/// [GlslSymbol] with an id, a name, a type and the scope that declares it.
/// Visibility follows GLSL: a name can be used only after its declaration, and
/// a nearer declaration hides an outer one with the same name.
library;

import 'dart:collection';

import 'package:source_span/source_span.dart';

import 'glsl_type.dart';

/// Owns the scopes and symbols of one shader, and assigns symbol ids.
final class SymbolTable {
  /// The root scope. It holds built-ins, uniforms, outputs, other globals,
  /// structs and functions.
  late final Scope global = Scope._(this, ScopeKind.global, null, null, null);

  final List<GlslSymbol> _symbols = [];

  /// Every symbol, in declaration order. A symbol's [GlslSymbol.id] is its
  /// index in this list.
  late final List<GlslSymbol> symbols = UnmodifiableListView(_symbols);

  /// The symbol with [id], or null if there is none.
  GlslSymbol? symbolById(int id) =>
      id >= 0 && id < _symbols.length ? _symbols[id] : null;

  /// The uniforms, in declaration order.
  ///
  /// Flutter assigns float uniform indices in this order, skipping samplers.
  Iterable<VariableSymbol> get uniforms => _symbols
      .whereType<VariableSymbol>()
      .where((variable) => variable.kind == VariableKind.uniform);

  /// The functions, in declaration order.
  Iterable<FunctionSymbol> get functions =>
      _symbols.whereType<FunctionSymbol>();
}

/// The kind of a [Scope].
enum ScopeKind {
  /// The whole file.
  global,

  /// A function's parameters and the top level of its body, which GLSL
  /// treats as one scope.
  function,

  /// A nested `{ }` block, or the header of a `for` loop.
  block,
}

/// A region of the shader where names are declared and looked up.
///
/// Create scopes through [SymbolTable.global], [openFunction] and [openBlock].
final class Scope {
  Scope._(this.table, this.kind, this.parent, this.function, this.span);

  /// The table this scope belongs to.
  final SymbolTable table;

  final ScopeKind kind;

  /// The enclosing scope, or null for the global scope.
  final Scope? parent;

  /// The function this scope belongs to, or null for the global scope.
  final FunctionSymbol? function;

  /// Where the scope is in the source, or null for the global scope. A
  /// function scope runs from its parameter list to its closing brace.
  final FileSpan? span;

  final List<Scope> _children = [];
  final List<GlslSymbol> _symbols = [];
  final Map<String, List<GlslSymbol>> _byName = {};

  /// The scopes opened directly inside this one, in source order.
  late final List<Scope> children = UnmodifiableListView(_children);

  /// The symbols declared directly in this scope, in declaration order.
  late final List<GlslSymbol> symbols = UnmodifiableListView(_symbols);

  /// The variables declared directly in this scope, in declaration order.
  Iterable<VariableSymbol> get variables =>
      _symbols.whereType<VariableSymbol>();

  /// How many scopes enclose this one. The global scope has depth 0.
  int get depth {
    var depth = 0;
    for (var scope = parent; scope != null; scope = scope.parent) {
      depth++;
    }
    return depth;
  }

  /// Opens the scope of [function]'s definition.
  ///
  /// Valid only on the global scope that declares [function], and only once
  /// per function.
  Scope openFunction(FunctionSymbol function, {FileSpan? span}) {
    if (kind != ScopeKind.global) {
      throw StateError('Functions can only be defined at global scope.');
    }
    if (!identical(function.scope, this)) {
      throw ArgumentError.value(
        function,
        'function',
        'Not declared in this scope',
      );
    }
    if (function._body != null) {
      throw StateError('${function.name} already has a body.');
    }
    final scope = Scope._(table, ScopeKind.function, this, function, span);
    function._body = scope;
    _children.add(scope);
    return scope;
  }

  /// Opens a nested block. Valid only inside a function.
  Scope openBlock({FileSpan? span}) {
    if (kind == ScopeKind.global) {
      throw StateError('Blocks can only be opened inside a function.');
    }
    final scope = Scope._(table, ScopeKind.block, this, function, span);
    _children.add(scope);
    return scope;
  }

  /// Declares a variable in this scope.
  ///
  /// [span] is the declared name in the source. [visibleFrom] is the source
  /// offset where the name starts to refer to this variable; it defaults to
  /// the end of [span]. GLSL makes a variable visible only after its whole
  /// declarator, so for `float x = x + 1.0;` pass the offset after the
  /// initializer, where the `x` on the right still means an outer `x`. Pass
  /// it explicitly as well when [span] is in another file, such as an
  /// included one.
  ///
  /// [direction] applies to parameters only and defaults to `in`.
  ///
  /// Throws a [StateError] if GLSL does not allow [kind] in this scope:
  /// uniforms, outputs and globals belong to the global scope, parameters to
  /// a function scope, and locals to function and block scopes.
  VariableSymbol declareVariable(
    String name,
    GlslType type, {
    required VariableKind kind,
    FileSpan? span,
    int? visibleFrom,
    bool isConst = false,
    ParameterDirection? direction,
  }) {
    final allowed = switch (kind) {
      VariableKind.parameter => this.kind == ScopeKind.function,
      VariableKind.local => this.kind != ScopeKind.global,
      VariableKind.uniform ||
      VariableKind.output ||
      VariableKind.global => this.kind == ScopeKind.global,
    };
    if (!allowed) {
      throw StateError(
        'A ${kind.name} variable cannot be declared in a ${this.kind.name} scope.',
      );
    }
    if (direction != null && kind != VariableKind.parameter) {
      throw ArgumentError.value(
        direction,
        'direction',
        'Only parameters have a direction',
      );
    }
    return _add(
      VariableSymbol._(
        id: table._symbols.length,
        name: name,
        scope: this,
        span: span,
        visibleFrom: visibleFrom,
        type: type,
        kind: kind,
        isConst: isConst,
        direction: kind == VariableKind.parameter
            ? direction ?? ParameterDirection.input
            : null,
      ),
    );
  }

  /// Declares a function at global scope, from a prototype or a definition.
  ///
  /// Open its body with [openFunction]. Each overload is a separate symbol.
  FunctionSymbol declareFunction(
    String name,
    GlslType returnType, {
    Iterable<FunctionParameter> parameters = const [],
    FileSpan? span,
    int? visibleFrom,
  }) {
    if (kind != ScopeKind.global) {
      throw StateError('Functions can only be declared at global scope.');
    }
    return _add(
      FunctionSymbol._(
        id: table._symbols.length,
        name: name,
        scope: this,
        span: span,
        visibleFrom: visibleFrom,
        returnType: returnType,
        parameters: parameters,
      ),
    );
  }

  /// Declares a struct type in this scope.
  StructSymbol declareStruct(
    StructType type, {
    FileSpan? span,
    int? visibleFrom,
  }) => _add(
    StructSymbol._(
      id: table._symbols.length,
      scope: this,
      span: span,
      visibleFrom: visibleFrom,
      type: type,
    ),
  );

  T _add<T extends GlslSymbol>(T symbol) {
    _symbols.add(symbol);
    (_byName[symbol.name] ??= []).add(symbol);
    table._symbols.add(symbol);
    return symbol;
  }

  /// The nearest symbol called [name] that is visible at source offset [at].
  ///
  /// Searches this scope, then each enclosing scope. When [at] is null, every
  /// declaration counts, as if looking from the end of this scope. Within one
  /// scope the first declaration wins; GLSL rejects a second one anyway.
  GlslSymbol? lookup(String name, {int? at}) {
    for (Scope? scope = this; scope != null; scope = scope.parent) {
      final found = scope._visibleNamed(name, at).firstOrNull;
      if (found != null) return found;
    }
    return null;
  }

  /// The overloads of function [name] visible at [at].
  ///
  /// Empty if there is no such function, or if a variable or struct with the
  /// same name in a nearer scope hides it.
  List<FunctionSymbol> lookupFunctions(String name, {int? at}) {
    final nearest = lookup(name, at: at);
    if (nearest is! FunctionSymbol) return const [];
    return nearest.scope
        ._visibleNamed(name, at)
        .whereType<FunctionSymbol>()
        .toList();
  }

  /// The variables visible at source offset [at]: innermost scope first, in
  /// declaration order within each scope.
  ///
  /// A variable hidden by a nearer declaration of the same name (a variable,
  /// struct or function) is left out. When [at] is null, every declaration
  /// counts, as if looking from the end of this scope.
  List<VariableSymbol> visibleVariables({int? at}) {
    final hidden = <String>{};
    final result = <VariableSymbol>[];
    for (Scope? scope = this; scope != null; scope = scope.parent) {
      final declaredHere = <String>{};
      for (final symbol in scope._symbols) {
        if (!symbol.isVisibleAt(at) || hidden.contains(symbol.name)) continue;
        if (!declaredHere.add(symbol.name)) continue;
        if (symbol is VariableSymbol) result.add(symbol);
      }
      hidden.addAll(declaredHere);
    }
    return result;
  }

  Iterable<GlslSymbol> _visibleNamed(String name, int? at) =>
      (_byName[name] ?? const <GlslSymbol>[]).where(
        (symbol) => symbol.isVisibleAt(at),
      );

  @override
  String toString() => switch (kind) {
    ScopeKind.global => 'Scope(global)',
    _ => 'Scope(${kind.name} in ${function?.name}, depth $depth)',
  };
}

/// Where a variable is declared. The picker groups variables by kind.
enum VariableKind {
  /// A `uniform`: the same for every pixel of a draw. Auto sliders (M4) are
  /// built from these.
  uniform,

  /// A global `out` variable, such as `fragColor`.
  output,

  /// Any other global variable, including global constants.
  global,

  /// A function parameter.
  parameter,

  /// A local variable, including one declared in a `for` header.
  local;

  /// Whether variables of this kind live in the global scope.
  bool get isGlobal => this == uniform || this == output || this == global;
}

/// The direction of a function parameter.
enum ParameterDirection {
  /// `in`, the default: the function only reads the argument.
  input('in'),

  /// `out`: the function writes the argument.
  output('out'),

  /// `inout`: the function reads and writes the argument.
  inputOutput('inout');

  const ParameterDirection(this.keyword);

  /// The GLSL qualifier.
  final String keyword;

  /// Whether a call writes the variable passed for this parameter.
  bool get writesArgument => this != input;
}

/// A named declaration recorded in a [Scope].
///
/// Symbols are created only through a scope's `declare` methods. Each has an
/// [id] that is unique within its [SymbolTable], and symbols compare by
/// identity.
sealed class GlslSymbol {
  GlslSymbol._({
    required this.id,
    required this.name,
    required this.scope,
    required this.span,
    required int? visibleFrom,
  }) : visibleFrom = visibleFrom ?? span?.end.offset ?? 0;

  /// The symbol's index in [SymbolTable.symbols].
  final int id;

  final String name;

  /// The scope that declares this symbol.
  final Scope scope;

  /// The declared name in the source, or null for a symbol with no source.
  final FileSpan? span;

  /// The source offset from which [name] refers to this symbol.
  final int visibleFrom;

  /// Whether this symbol is visible at source [offset]. A null [offset] means
  /// "at the end of the scope", where every declaration is visible.
  bool isVisibleAt(int? offset) => offset == null || visibleFrom <= offset;
}

/// A variable: a uniform, output, global, parameter or local.
final class VariableSymbol extends GlslSymbol {
  VariableSymbol._({
    required super.id,
    required super.name,
    required super.scope,
    required super.span,
    required super.visibleFrom,
    required this.type,
    required this.kind,
    required this.isConst,
    required this.direction,
  }) : super._();

  final GlslType type;
  final VariableKind kind;

  /// Whether the variable is declared `const`.
  final bool isConst;

  /// The direction of a parameter, or null for other kinds.
  final ParameterDirection? direction;

  @override
  String toString() => '${kind.name} $type $name #$id';
}

/// One overload of a function, from its prototype or definition.
final class FunctionSymbol extends GlslSymbol {
  FunctionSymbol._({
    required super.id,
    required super.name,
    required super.scope,
    required super.span,
    required super.visibleFrom,
    required this.returnType,
    required Iterable<FunctionParameter> parameters,
  }) : parameters = List.unmodifiable(parameters),
       super._();

  final GlslType returnType;

  /// The parameters, in order. A call writes the arguments passed for
  /// `out` and `inout` parameters.
  final List<FunctionParameter> parameters;

  Scope? _body;

  /// The function's own scope, or null while only a prototype has been seen.
  Scope? get body => _body;

  /// Whether the function has a definition, not just a prototype.
  bool get isDefined => _body != null;

  /// Whether this is `void main()`, the entry point the instrumenter renames.
  bool get isMain =>
      name == 'main' && parameters.isEmpty && returnType == GlslType.voidType;

  @override
  String toString() => '$returnType $name(${parameters.join(', ')}) #$id';
}

/// A parameter in a function's signature.
///
/// The parameter's [VariableSymbol] exists only inside a definition's scope.
/// This describes the signature, which prototypes have too.
final class FunctionParameter {
  const FunctionParameter(
    this.type, {
    this.name,
    this.direction = ParameterDirection.input,
    this.isConst = false,
  });

  final GlslType type;

  /// The parameter's name, or null where a prototype leaves it out.
  final String? name;

  final ParameterDirection direction;

  /// Whether the parameter is declared `const`.
  final bool isConst;

  @override
  String toString() => [
    if (isConst) 'const',
    if (direction != ParameterDirection.input) direction.keyword,
    '$type',
    ?name,
  ].join(' ');
}

/// A struct type declaration.
final class StructSymbol extends GlslSymbol {
  StructSymbol._({
    required super.id,
    required super.scope,
    required super.span,
    required super.visibleFrom,
    required this.type,
  }) : super._(name: type.name);

  final StructType type;

  @override
  String toString() => 'struct $name #$id';
}
