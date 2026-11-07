/// The debugger's state and its two flows (docs/architecture.md, "How a
/// heatmap gets on screen"): analyze the shader, let the user pick a value,
/// load a probe for it into the app, then have the app draw it as a heatmap
/// or read it at a pixel.
library;

import 'dart:async';
import 'dart:ui' show Offset, Size;

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

  /// Writing the probe and hot reloading the app so it compiles it.
  writing,

  /// Asking the app to draw the probe, until it has loaded it.
  loading,
  shown,
  failed,
}

/// Where reading a pixel stands.
enum PixelStatus {
  off,

  /// Waiting for a tap in the app.
  picking,

  /// Loading the probe and reading the value.
  reading,
  shown,
  failed,
}

/// The captured value at a pixel, as the app read it.
@immutable
final class PixelValue {
  const PixelValue({
    required this.probe,
    required this.coord,
    required this.components,
  });

  /// The probe that captured it: what was captured, of which type, where.
  final Probe probe;

  /// Where, in the shader's coordinates.
  final Offset coord;

  /// x, y, z and w; only the first `probe.visualization.componentCount`
  /// carry the value.
  final List<double> components;
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
  String? get expression {
    final name = _variable?.name;
    if (name == null) return null;
    return _path.fold<String>(name, (text, step) => step.applyTo(text));
  }

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
  _Selection? _manualSelection;

  double get min => _min;
  double _min = 0;

  double get max => _max;
  double _max = 1;

  PixelStatus get pixelStatus => _pixelStatus;
  PixelStatus _pixelStatus = PixelStatus.off;

  /// Progress or failure details for [pixelStatus].
  String? get pixelMessage => _pixelMessage;
  String? _pixelMessage;

  /// The point to read, in the shader's coordinates.
  Offset? get pixel => _pixel;
  Offset? _pixel;

  /// The size of the area the shader was painted in, when [pixel] was
  /// picked in the app.
  Size? get pixelArea => _pixelArea;
  Size? _pixelArea;

  /// Which `DebugShader` [pixel] was picked on; null for the first one.
  int? _pixelInstance;

  /// The value last read at [pixel].
  PixelValue? get pixelValue => _pixelValue;
  PixelValue? _pixelValue;

  StreamSubscription<PixelPick>? _picks;

  /// The probe the app has loaded, as far as the debugger knows, and the
  /// selection it captures. The heatmap and pixel reads share it.
  Probe? _loadedProbe;
  _Selection? _loadedSelection;

  /// The probe file as it was before the debugger first wrote it.
  String? _originalProbeSource;

  /// Loads run one at a time, so their writes and reloads do not interleave.
  Future<void> _loadQueue = Future.value();
  final _loads = <_Selection, Future<_Load>>{};

  int _lastStamp = 0;

  /// Bumped by every user action that changes the heatmap, or the pixel
  /// reading, so an older operation still in flight can tell it has been
  /// superseded.
  int _operation = 0;
  int _pixelOperation = 0;
  bool _disposed = false;

  /// The probe's file, once the app's directory is known.
  Uri? get probeFile {
    final root = _appRoot;
    final info = _info;
    return root == null || info == null ? null : root.resolve(info.probeAsset);
  }

  /// Whether a heatmap can be requested now.
  bool get canShow => _canLoad && !isBusy;

  /// Whether a pixel can be read or picked now.
  bool get canReadPixel => _canLoad && _pixelStatus != PixelStatus.reading;

  bool get _canLoad =>
      _connection == AppConnection.ready &&
      _appRoot != null &&
      _statement != null &&
      _variable != null;

  bool get isBusy => switch (_status) {
    HeatmapStatus.writing || HeatmapStatus.loading => true,
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
    unawaited(_picks?.cancel());
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
          'package:shader_debugger in the app, and hot restart it.',
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
    await _forgetPixel();
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
  /// part it writes, for a composite. While a heatmap or a pixel value is
  /// shown and [live] is true, shows the new value right away.
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
    if (live) _updateLive();
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
    _updateLive();
  }

  /// Changes the step of [path] at [depth] to [selector], then goes on to
  /// the first drawable part below it. While a heatmap or a pixel value is
  /// shown, shows the new part right away.
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
    _updateLive();
  }

  void _updateLive() {
    if (_status == HeatmapStatus.shown && canShow) showHeatmap();
    if (_pixelStatus == PixelStatus.shown && _pixel != null) readPixel();
  }

  // Heatmap.

  /// Loads the probe for the selection into the app, and has the app draw
  /// it in place of the shader.
  Future<void> showHeatmap() async {
    final selection = _selection;
    final asset = _asset;
    if (selection == null || asset == null || probeFile == null) return;
    final operation = ++_operation;
    if (!_isLoaded(selection)) {
      _setStatus(HeatmapStatus.writing, 'Writing the probe and hot reloading…');
    }
    final load = await _load(selection);
    if (operation != _operation) return;
    final probe = load.probe;
    if (probe == null) {
      // Do not leave an older value on screen under a failure.
      await _hideQuietly();
      if (operation != _operation) return;
      _setStatus(HeatmapStatus.failed, load.error);
      return;
    }
    _setStatus(HeatmapStatus.loading, 'Waiting for the app to load the probe…');
    final answer = await _askUntilLoaded(
      () => app.showHeatmap(
        asset: asset,
        stamp: probe.stamp,
        min: _min,
        max: _max,
      ),
      () => operation != _operation,
    );
    if (operation != _operation) return;
    switch (answer) {
      case _Failure(:final message):
        _setStatus(HeatmapStatus.failed, message);
      default:
        _shownProbe = probe;
        _setStatus(HeatmapStatus.shown, null);
    }
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
    _manualSelection = null;
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

  // Pixel.

  /// Has the app report the next tap on the shader, then reads the value
  /// there. The tap also reaches the app.
  Future<void> pickPixel() async {
    final asset = _asset;
    if (asset == null || _connection != AppConnection.ready) return;
    final operation = ++_pixelOperation;
    await _picks?.cancel();
    _picks = app.pixelPicks.listen((pick) {
      if (pick.asset != asset || operation != _pixelOperation) return;
      unawaited(_picks?.cancel());
      _picks = null;
      if (!pick.hit) {
        _setPixel(
          PixelStatus.failed,
          'That tap was not on $asset. Pick again, on the shader.',
        );
        return;
      }
      _pixel = Offset(pick.x!, pick.y!);
      _pixelInstance = pick.instance;
      final width = pick.width;
      final height = pick.height;
      _pixelArea = width == null || height == null ? null : Size(width, height);
      readPixel();
    });
    _setPixel(PixelStatus.picking, 'Click the shader in the app…');
    try {
      await app.pickPixel(asset);
    } on Object catch (error) {
      if (operation != _pixelOperation) return;
      await _picks?.cancel();
      _picks = null;
      _setPixel(PixelStatus.failed, 'The app did not answer: $error');
    }
  }

  /// Stops waiting for a tap.
  Future<void> cancelPick() async {
    if (_pixelStatus != PixelStatus.picking) return;
    ++_pixelOperation;
    await _picks?.cancel();
    _picks = null;
    _setPixel(_pixelValue == null ? PixelStatus.off : PixelStatus.shown, null);
    try {
      await app.cancelPick();
    } on Object {
      // The app may be gone.
    }
  }

  /// Reads the value at ([x], [y]), typed in the shader's coordinates.
  Future<void> setPixel(double x, double y) {
    _pixel = Offset(x, y);
    return readPixel();
  }

  /// Loads the probe for the selection into the app, and reads the value at
  /// [pixel].
  Future<void> readPixel() async {
    final selection = _selection;
    final asset = _asset;
    final coord = _pixel;
    if (selection == null ||
        asset == null ||
        coord == null ||
        probeFile == null) {
      return;
    }
    final operation = ++_pixelOperation;
    await _picks?.cancel();
    _picks = null;
    _setPixel(
      PixelStatus.reading,
      _isLoaded(selection)
          ? 'Reading…'
          : 'Writing the probe and hot reloading…',
    );
    final load = await _load(selection);
    if (operation != _pixelOperation) return;
    final probe = load.probe;
    if (probe == null) {
      _setPixel(PixelStatus.failed, load.error);
      return;
    }
    final answer = await _askUntilLoaded(
      () => app.readPixel(
        asset: asset,
        stamp: probe.stamp,
        x: coord.dx,
        y: coord.dy,
        instance: _pixelInstance,
      ),
      () => operation != _pixelOperation,
    );
    if (operation != _pixelOperation) return;
    switch (answer) {
      case PixelAnswer(applied: true, :final value?):
        _pixelValue = PixelValue(probe: probe, coord: coord, components: value);
        _setPixel(PixelStatus.shown, null);
      case _Failure(:final message):
        _setPixel(PixelStatus.failed, message);
      default:
        _setPixel(PixelStatus.failed, 'The app answered without a value.');
    }
  }

  Future<void> _forgetPixel() async {
    if (_pixelStatus == PixelStatus.picking) await cancelPick();
    ++_pixelOperation;
    _pixel = null;
    _pixelArea = null;
    _pixelInstance = null;
    _pixelValue = null;
    _pixelStatus = PixelStatus.off;
    _pixelMessage = null;
  }

  // Loading probes.

  /// After the user pasted [manualProbe] and hot reloaded: takes it as
  /// loaded, and retries what needed it.
  Future<void> checkManualProbe() async {
    final probe = _manualProbe;
    final selection = _manualSelection;
    if (probe == null || selection == null) return;
    _loadedProbe = probe;
    _loadedSelection = selection;
    _manualProbe = null;
    _manualSelection = null;
    await Future.wait([
      if (_status == HeatmapStatus.failed) showHeatmap(),
      if (_pixelStatus == PixelStatus.failed && _pixel != null) readPixel(),
    ]);
  }

  _Selection? get _selection {
    final analysis = _analysis;
    final statement = _statement;
    final variable = _variable;
    if (!_canLoad || analysis == null) return null;
    return _Selection(analysis, statement!, variable!, _path);
  }

  bool _isLoaded(_Selection selection) =>
      _loadedProbe != null && _loadedSelection == selection;

  /// The probe for [selection], loaded into the app: the one it already has,
  /// or a new one, written and hot reloaded. Callers asking for the same
  /// selection at the same time share one load.
  Future<_Load> _load(_Selection selection) {
    final loaded = _loadedProbe;
    if (loaded != null && _loadedSelection == selection) {
      return Future.value(_Load(loaded));
    }
    return _loads[selection] ??= () async {
      final previous = _loadQueue;
      final done = Completer<void>();
      _loadQueue = done.future;
      try {
        await previous;
        return await _writeAndReload(selection);
      } finally {
        _loads.remove(selection);
        done.complete();
      }
    }();
  }

  Future<_Load> _writeAndReload(_Selection selection) async {
    final loaded = _loadedProbe;
    if (loaded != null && _loadedSelection == selection) return _Load(loaded);
    final file = probeFile!;
    final Probe probe;
    try {
      probe = instrument(
        selection.analysis,
        CaptureRequest(
          statement: selection.statement,
          variable: selection.variable,
          path: selection.path,
        ),
        stamp: _nextStamp(),
      );
    } on InstrumentationException catch (error) {
      return _Load.failed(error.message);
    }

    _originalProbeSource ??= await _readOrNull(file);
    try {
      await workspace.write(file, probe.source);
    } on WorkspaceException catch (error) {
      _manualProbe = probe;
      _manualSelection = selection;
      return _Load.failed(
        '${_describe(error, file, writing: true)} You can paste the probe into '
        'that file yourself, hot reload, and press Check.',
      );
    }
    try {
      await app.hotReload();
    } on Object {
      // The app keeps the probe it had. Put that one back in the file, so
      // the next hot reload, the developer's own included, does not fail
      // on this one again.
      final previous = _loadedProbe?.source ?? _originalProbeSource;
      if (previous != null) {
        try {
          await workspace.write(file, previous);
        } on WorkspaceException {
          // Nothing more to do; the message below still applies.
        }
      }
      return _Load.failed(
        'Hot reload failed. If the probe does not compile, the Flutter tool '
        'prints why; please report it, with the shader.',
      );
    }
    _loadedProbe = probe;
    _loadedSelection = selection;
    return _Load(probe);
  }

  Future<String?> _readOrNull(Uri file) async {
    try {
      return await workspace.read(file);
    } on WorkspaceException {
      return null;
    }
  }

  /// Calls [ask] while the app answers that it has not loaded the probe yet,
  /// up to [retries] times. Returns the applied answer, or a [_Failure];
  /// stops early once [superseded].
  Future<Object> _askUntilLoaded(
    Future<ProbeAnswer> Function() ask,
    bool Function() superseded,
  ) async {
    final asset = _asset;
    for (var attempt = 1; attempt <= retries; attempt++) {
      final ProbeAnswer answer;
      try {
        answer = await ask();
      } on Object catch (error) {
        return _Failure('The app did not answer: $error');
      }
      if (answer.applied) return answer;
      if (answer.reason != 'probeNotLoaded') {
        return _Failure(_rejection(answer.reason, asset ?? ''));
      }
      if (attempt < retries) await Future<void>.delayed(retryDelay);
      if (superseded()) return const _Failure('superseded');
    }
    return const _Failure(
      'The app is still running an older probe. If the hot reload printed '
      'errors, they explain why.',
    );
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

  void _setPixel(PixelStatus status, String? message) {
    _pixelStatus = status;
    _pixelMessage = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

/// What a probe captures. Equal selections share a loaded probe.
@immutable
final class _Selection {
  const _Selection(this.analysis, this.statement, this.variable, this.path);

  final ShaderAnalysis analysis;
  final StatementInfo statement;
  final VariableSymbol variable;
  final List<Selector> path;

  @override
  bool operator ==(Object other) =>
      other is _Selection &&
      identical(other.analysis, analysis) &&
      identical(other.statement, statement) &&
      identical(other.variable, variable) &&
      listEquals(other.path, path);

  @override
  int get hashCode => Object.hash(
    identityHashCode(analysis),
    identityHashCode(statement),
    identityHashCode(variable),
    Object.hashAll(path),
  );
}

/// The result of loading a probe: the probe, or why it could not be loaded.
final class _Load {
  const _Load(Probe this.probe) : error = null;
  const _Load.failed(String this.error) : probe = null;

  final Probe? probe;
  final String? error;
}

/// Why asking the app failed, as a message for the user.
final class _Failure {
  const _Failure(this.message);

  final String message;
}
