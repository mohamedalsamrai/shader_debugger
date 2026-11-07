/// The debugger's state and the heatmap flow (docs/architecture.md, "How a
/// heatmap gets on screen"): analyze the shader, let the user pick a value,
/// write the probe, hot reload, and ask the app to show it.
library;

import 'package:flutter/foundation.dart';
import 'package:shader_debugger_core/shader_debugger_core.dart';

import 'ports.dart';

/// Where the connection to the app's runtime stands.
enum AppConnection {
  /// The app has not registered the runtime's service extensions yet.
  waiting,
  connecting,
  ready,
  failed,
}

/// Where showing a heatmap stands.
enum HeatmapStatus {
  off,

  /// Writing the probe file.
  writing,

  /// Hot reloading the app so it compiles the probe.
  reloading,

  /// Asking the app to draw the probe, until it has loaded it.
  loading,
  shown,
  failed,
}

class ShaderDebuggerController extends ChangeNotifier {
  ShaderDebuggerController({
    required this.app,
    required this.workspace,
    this.retryDelay = const Duration(milliseconds: 300),
    this.retries = 10,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final DebuggedApp app;
  final Workspace workspace;

  /// How long to wait between asks while the app loads a new probe.
  final Duration retryDelay;

  /// How many times to ask before giving up.
  final int retries;

  final int Function() _clock;

  AppConnection get connection => _connection;
  AppConnection _connection = AppConnection.waiting;

  /// Why connecting failed.
  String? get connectionError => _connectionError;
  String? _connectionError;

  AppInfo? get info => _info;
  AppInfo? _info;

  /// The app's package directory (where its pubspec.yaml is), as a file URI
  /// ending in `/`. Asset keys are relative to it.
  Uri? get appRoot => _appRoot;
  Uri? _appRoot;

  /// The asset key of the shader being looked at.
  String? get asset => _asset;
  String? _asset;

  ShaderAnalysis? get analysis => _analysis;
  ShaderAnalysis? _analysis;

  /// Why the shader's source could not be read.
  String? get sourceError => _sourceError;
  String? _sourceError;

  StatementInfo? get statement => _statement;
  StatementInfo? _statement;

  VariableSymbol? get variable => _variable;
  VariableSymbol? _variable;

  /// Steps from [variable] to the part shown, such as `[1]` for a matrix's
  /// second column. Empty when the variable is drawn whole.
  List<Selector> get path => _path;
  List<Selector> _path = const [];

  /// The GLSL expression shown, such as `lights[1].color`.
  String? get expression => _variable == null
      ? null
      : _path.fold(
          _variable!.name,
          (expression, step) => step.applyTo(expression),
        );

  /// The type of the part shown.
  GlslType? get valueType => _variable?.type.selectPath(_path);

  /// The type [path]'s step at [depth] picks from: the variable's type for
  /// depth 0, the part the step before picked for the others.
  GlslType? typeAt(int depth) => _variable?.type.selectPath(_path.take(depth));

  HeatmapStatus get status => _status;
  HeatmapStatus _status = HeatmapStatus.off;

  /// Progress or failure details for [status].
  String? get statusMessage => _statusMessage;
  String? _statusMessage;

  /// The probe the app is drawing, while [status] is [HeatmapStatus.shown].
  Probe? get shownProbe => _shownProbe;
  Probe? _shownProbe;

  /// A probe the debugger could not write itself. The user can paste it into
  /// [probeFile], hot reload, and call [checkManualProbe].
  Probe? get manualProbe => _manualProbe;
  Probe? _manualProbe;

  double get min => _min;
  double _min = 0;

  double get max => _max;
  double _max = 1;

  int _lastStamp = 0;

  /// Bumped by every user action that changes the heatmap, so an older
  /// operation still in flight can tell it has been superseded.
  int _operation = 0;
  bool _disposed = false;

  /// The probe's file, once the app's directory is known.
  Uri? get probeFile {
    final root = _appRoot;
    final info = _info;
    return root == null || info == null ? null : root.resolve(info.probeAsset);
  }

  /// Whether a heatmap can be requested now.
  bool get canShow =>
      _connection == AppConnection.ready &&
      _appRoot != null &&
      _statement != null &&
      _variable != null &&
      !isBusy;

  bool get isBusy => switch (_status) {
    HeatmapStatus.writing ||
    HeatmapStatus.reloading ||
    HeatmapStatus.loading => true,
    _ => false,
  };

  /// The 0-based lines that have a statement the user can pick.
  Set<int> get pickableLines => {
    for (final statement in _analysis?.statements ?? const <StatementInfo>[])
      if (statement.isPickable) statement.line,
  };

  /// Whether the probe can draw [variable], or a column, element or field
  /// of it.
  static bool isCapturable(VariableSymbol? variable) =>
      variable != null && variable.type.firstDrawablePath != null;

  /// Starts following the app: connects as soon as its runtime is there.
  void start() {
    app.hasRuntime.addListener(_runtimeChanged);
    _runtimeChanged();
  }

  @override
  void dispose() {
    _disposed = true;
    app.hasRuntime.removeListener(_runtimeChanged);
    super.dispose();
  }

  void _runtimeChanged() {
    if (app.hasRuntime.value && _connection == AppConnection.waiting) {
      connect();
    }
  }

  /// Asks the app what it draws, and finds its package directory.
  Future<void> connect() async {
    _connection = AppConnection.connecting;
    _connectionError = null;
    _notify();
    try {
      final info = await app.getInfo();
      if (info.protocolVersion != protocolVersion) {
        _fail(
          'The app speaks protocol version ${info.protocolVersion}, but this '
          'extension speaks version $protocolVersion. Use the same version of '
          'package:shader_debugger in the app.',
        );
        return;
      }
      _info = info;
      _appRoot ??= await _findAppRoot();
      _connection = AppConnection.ready;
      _notify();
      final current = _asset;
      if (current != null && info.shaders.contains(current)) return;
      if (info.shaders.isNotEmpty) await selectShader(info.shaders.first);
    } on Object catch (error) {
      _fail('Could not reach the app: $error');
    }
  }

  void _fail(String message) {
    _connection = AppConnection.failed;
    _connectionError = message;
    _notify();
  }

  /// The directory above the main library that holds pubspec.yaml. Without
  /// file access, falls back to the directory above the last `lib`.
  Future<Uri?> _findAppRoot() async {
    final library = await app.rootLibrary();
    if (library == null) return null;
    var directory = library.resolve('.');
    while (true) {
      try {
        await workspace.read(directory.resolve('pubspec.yaml'));
        return directory;
      } on WorkspaceException catch (error) {
        if (error.error != WorkspaceError.notFound) break;
      }
      final parent = directory.resolve('..');
      if (parent == directory) break;
      directory = parent;
    }
    final segments = library.pathSegments;
    final lib = segments.lastIndexOf('lib');
    if (lib <= 0) return null;
    return library.replace(pathSegments: [...segments.take(lib), '']);
  }

  /// Reads and analyzes the shader at [asset].
  Future<void> selectShader(String asset) async {
    _asset = asset;
    _analysis = null;
    _sourceError = null;
    _statement = null;
    _variable = null;
    _path = const [];
    _notify();
    await reloadSource();
  }

  /// Reads the current shader again, after it was edited.
  Future<void> reloadSource() async {
    final asset = _asset;
    final root = _appRoot;
    if (asset == null) return;
    if (root == null) {
      _sourceError =
          "Cannot tell where the app's files are: DevTools did not report its "
          'main library.';
      _notify();
      return;
    }
    final file = root.resolve(asset);
    try {
      final source = await workspace.read(file);
      if (_asset != asset) return;
      final analysis = analyzeShader(source, url: file);
      _analysis = analysis;
      _sourceError = null;
      // Keep the selection on the same line, if it is still pickable there.
      final line = _statement?.line;
      _statement = null;
      _variable = null;
      _path = const [];
      if (line != null) selectLine(line, live: false);
    } on WorkspaceException catch (error) {
      if (_asset != asset) return;
      _sourceError = _describe(error, file, writing: false);
    }
    _notify();
  }

  /// Selects the statement on 0-based [line], and the value it writes: the
  /// part it writes, for a composite. While a heatmap is shown and [live] is
  /// true, shows the new value right away.
  void selectLine(int line, {bool live = true}) {
    final candidates = [
      for (final statement
          in _analysis?.statementsOnLine(line) ?? const <StatementInfo>[])
        if (statement.isPickable) statement,
    ];
    if (candidates.isEmpty) return;
    final statement =
        candidates.where((s) => isCapturable(s.defaultPick)).lastOrNull ??
        candidates.last;
    _statement = statement;
    final variable = isCapturable(statement.defaultPick)
        ? statement.defaultPick
        : statement.inScope.where(isCapturable).firstOrNull;
    _variable = variable;
    _path = variable == null
        ? const []
        : List.unmodifiable(statement.defaultPath(variable)!);
    _notify();
    if (live) _showIfLive();
  }

  /// Selects which in-scope [variable] to show; for a composite, the part
  /// the statement writes, or else its first drawable part.
  void selectVariable(VariableSymbol variable) {
    final statement = _statement;
    if (statement == null || !isCapturable(variable) || _variable == variable) {
      return;
    }
    _variable = variable;
    _path = List.unmodifiable(statement.defaultPath(variable)!);
    _notify();
    _showIfLive();
  }

  /// Changes the step of [path] at [depth] to [selector], then goes on to
  /// the first drawable part below it. While a heatmap is shown, shows the
  /// new part right away.
  void selectStep(int depth, Selector selector) {
    final variable = _variable;
    if (variable == null || depth < 0 || depth >= _path.length) return;
    final prefix = [..._path.take(depth), selector];
    final rest = variable.type.selectPath(prefix)?.firstDrawablePath;
    if (rest == null) return;
    final path = [...prefix, ...rest];
    if (listEquals(path, _path)) return;
    _path = List.unmodifiable(path);
    _notify();
    _showIfLive();
  }

  void _showIfLive() {
    if (_status == HeatmapStatus.shown && canShow) showHeatmap();
  }

  /// Generates the probe for the selection, writes it, hot reloads, and has
  /// the app draw it.
  Future<void> showHeatmap() async {
    final analysis = _analysis;
    final statement = _statement;
    final variable = _variable;
    final asset = _asset;
    final file = probeFile;
    if (analysis == null ||
        statement == null ||
        variable == null ||
        asset == null ||
        file == null) {
      return;
    }
    final operation = ++_operation;
    final Probe probe;
    try {
      probe = instrument(
        analysis,
        CaptureRequest(statement: statement, variable: variable, path: _path),
        stamp: _nextStamp(),
      );
    } on InstrumentationException catch (error) {
      _setStatus(HeatmapStatus.failed, error.message);
      return;
    }
    _manualProbe = null;

    _setStatus(HeatmapStatus.writing, 'Writing the probe…');
    try {
      await workspace.write(file, probe.source);
    } on WorkspaceException catch (error) {
      if (operation != _operation) return;
      _manualProbe = probe;
      _setStatus(
        HeatmapStatus.failed,
        '${_describe(error, file, writing: true)} You can paste the probe into '
        'that file yourself, hot reload, and press Check.',
      );
      return;
    }
    if (operation != _operation) return;

    _setStatus(HeatmapStatus.reloading, 'Hot reloading…');
    try {
      await app.hotReload();
    } on Object {
      if (operation != _operation) return;
      await _hideQuietly();
      _setStatus(
        HeatmapStatus.failed,
        'Hot reload failed. If the probe does not compile, the Flutter tool '
        'prints why; please report it, with the shader.',
      );
      return;
    }
    if (operation != _operation) return;
    await _waitForProbe(probe, asset, operation);
  }

  /// After the user pasted [manualProbe] and hot reloaded: has the app draw it.
  Future<void> checkManualProbe() async {
    final probe = _manualProbe;
    final asset = _asset;
    if (probe == null || asset == null) return;
    await _waitForProbe(probe, asset, ++_operation);
  }

  Future<void> _waitForProbe(Probe probe, String asset, int operation) async {
    _setStatus(HeatmapStatus.loading, 'Waiting for the app to load the probe…');
    for (var attempt = 1; attempt <= retries; attempt++) {
      final HeatmapAnswer answer;
      try {
        answer = await app.showHeatmap(
          asset: asset,
          stamp: probe.stamp,
          min: _min,
          max: _max,
        );
      } on Object catch (error) {
        if (operation != _operation) return;
        _setStatus(HeatmapStatus.failed, 'The app did not answer: $error');
        return;
      }
      if (operation != _operation) return;
      if (answer.applied) {
        _shownProbe = probe;
        _manualProbe = null;
        _setStatus(HeatmapStatus.shown, null);
        return;
      }
      if (answer.reason != 'probeNotLoaded') {
        _setStatus(HeatmapStatus.failed, _rejection(answer.reason, asset));
        return;
      }
      if (attempt < retries) await Future<void>.delayed(retryDelay);
      if (operation != _operation) return;
    }
    _setStatus(
      HeatmapStatus.failed,
      'The app is still running an older probe. If the hot reload printed '
      'errors, they explain why.',
    );
  }

  /// Sets the value range the colormap spans. While a heatmap is shown, the
  /// app redraws with it; no reload is needed.
  Future<void> setRange(double min, double max) async {
    _min = min;
    _max = max;
    _notify();
    final probe = _shownProbe;
    final asset = _asset;
    if (_status != HeatmapStatus.shown || probe == null || asset == null) {
      return;
    }
    final operation = ++_operation;
    try {
      final answer = await app.showHeatmap(
        asset: asset,
        stamp: probe.stamp,
        min: min,
        max: max,
      );
      if (operation != _operation || answer.applied) return;
      _setStatus(HeatmapStatus.failed, _rejection(answer.reason, asset));
    } on Object catch (error) {
      if (operation != _operation) return;
      _setStatus(HeatmapStatus.failed, 'The app did not answer: $error');
    }
  }

  /// Has the app draw its original shaders again.
  Future<void> hideHeatmap() async {
    ++_operation;
    _manualProbe = null;
    await _hideQuietly();
    _setStatus(HeatmapStatus.off, null);
  }

  Future<void> _hideQuietly() async {
    _shownProbe = null;
    try {
      await app.hideHeatmap();
    } on Object {
      // The app may be gone; nothing is shown then either.
    }
  }

  int _nextStamp() {
    // Seconds since 2026 keep stamps unique across sessions of the extension.
    final now = (_clock() ~/ 1000) % 1000000000;
    return _lastStamp = now > _lastStamp ? now : _lastStamp + 1;
  }

  String _rejection(String? reason, String asset) => switch (reason) {
    'noShaderForAsset' =>
      'No DebugShader in the app draws $asset any more. Is the widget still on screen?',
    'probeMissing' =>
      'The app cannot load ${_info?.probeAsset}. Register it under '
          '`flutter: shaders:` in the app\'s pubspec.yaml, then restart the app.',
    _ => 'The app refused the probe ($reason).',
  };

  String _describe(
    WorkspaceException error,
    Uri file, {
    required bool writing,
  }) {
    final path = file.toFilePath();
    final verb = writing ? 'write' : 'read';
    return switch (error.error) {
      WorkspaceError.unavailable =>
        'DevTools cannot $verb files: it has no connection to the Dart Tooling '
            'Daemon. Run the app from VS Code or Android Studio.',
      WorkspaceError.permissionDenied =>
        'DevTools may only $verb files inside the IDE\'s workspace folders, '
            'and $path is not in one. Open the app\'s folder in VS Code or '
            'Android Studio and run it from there.',
      WorkspaceError.notFound => '$path does not exist.',
      WorkspaceError.other => 'Could not $verb $path: ${error.message}',
    };
  }

  void _setStatus(HeatmapStatus status, String? message) {
    _status = status;
    _statusMessage = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
