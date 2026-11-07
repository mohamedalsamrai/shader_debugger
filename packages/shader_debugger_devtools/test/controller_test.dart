import 'dart:async';

import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:shader_debugger_devtools/src/controller.dart';
import 'package:shader_debugger_devtools/src/ports.dart';

import 'fakes.dart';

void main() {
  late FakeWorkspace workspace;
  late FakeApp app;
  late ShaderDebuggerController controller;
  var clock = 0;

  setUp(() {
    workspace = FakeWorkspace();
    app = FakeApp(workspace);
    clock = 1000000;
    controller = ShaderDebuggerController(
      app: app,
      workspace: workspace,
      retryDelay: Duration.zero,
      retries: 5,
      clock: () => clock,
    );
  });

  tearDown(() => controller.dispose());

  /// Starts the controller with the runtime present, and waits until the
  /// first shader is analyzed.
  Future<void> connect() async {
    app.runtime.value = true;
    controller.start();
    await pumpEventQueue();
    expect(controller.connection, AppConnection.ready);
  }

  group('connecting', () {
    test('waits for the runtime, then connects on its own', () async {
      controller.start();
      expect(controller.connection, AppConnection.waiting);
      app.runtime.value = true;
      await pumpEventQueue();
      expect(controller.connection, AppConnection.ready);
      expect(controller.appRoot, appRoot);
      expect(controller.probeFile, probeFile);
      expect(controller.asset, gradientAsset);
      expect(controller.analysis?.uniforms.map((u) => u.name), [
        'uSize',
        'uA',
        'uB',
      ]);
    });

    test('finds the package directory by walking up to pubspec.yaml', () async {
      app.mainLibrary = appRoot.resolve('lib/src/deep/main.dart');
      await connect();
      expect(controller.appRoot, appRoot);
    });

    test('without file access, guesses the directory above lib/', () async {
      workspace.failWith = WorkspaceError.permissionDenied;
      await connect();
      expect(controller.appRoot, appRoot);
      expect(
        controller.sourceError,
        contains("inside the IDE's workspace folders"),
      );
    });

    test('refuses an app that speaks another protocol version', () async {
      app.info = const AppInfo(
        protocolVersion: 99,
        probeAsset: probeAsset,
        shaders: [],
      );
      app.runtime.value = true;
      controller.start();
      await pumpEventQueue();
      expect(controller.connection, AppConnection.failed);
      expect(controller.connectionError, contains('protocol version 99'));
    });
  });

  group('picking', () {
    setUp(connect);

    test('a line selects its statement and the value it writes', () {
      controller.selectLine(lineOf('float d ='));
      expect(controller.statement?.span.text, 'float d = length(uv - 0.5);');
      expect(controller.variable?.name, 'd');
      expect(controller.canShow, isTrue);
    });

    test('a line without a statement changes nothing', () {
      controller.selectLine(lineOf('float d ='));
      controller.selectLine(lineOf('uniform vec2 uSize;'));
      expect(controller.variable?.name, 'd');
    });

    test('marks the lines that can be picked', () {
      expect(controller.pickableLines, {
        lineOf('vec2 uv ='),
        lineOf('float d ='),
        lineOf('vec3 col ='),
        lineOf('fragColor ='),
      });
    });

    test('rereading the source keeps the picked line', () async {
      controller.selectLine(lineOf('float d ='));
      await controller.reloadSource();
      expect(controller.statement?.span.text, 'float d = length(uv - 0.5);');
    });
  });

  group('showing a heatmap', () {
    setUp(() async {
      await connect();
      controller.selectLine(lineOf('float d ='));
    });

    test('writes the probe, hot reloads, and has the app draw it', () async {
      await controller.showHeatmap();
      expect(
        workspace.files[probeFile],
        contains('_dbg_value = vec4(d, 0.0, 0.0, 1.0);'),
      );
      expect(app.reloads, 1);
      expect(controller.status, HeatmapStatus.shown);
      expect(controller.shownProbe?.request.expression, 'd');
      expect(app.shown, (
        asset: gradientAsset,
        stamp: controller.shownProbe!.stamp,
        min: 0.0,
        max: 1.0,
      ));
    });

    test('asks again while the reloaded probe lands', () async {
      app.slowAsks = 3;
      await controller.showHeatmap();
      expect(controller.status, HeatmapStatus.shown);
      expect(app.heatmapCalls, hasLength(4));
    });

    test('gives up when the new probe never loads', () async {
      app.slowAsks = 100;
      await controller.showHeatmap();
      expect(controller.status, HeatmapStatus.failed);
      expect(controller.statusMessage, contains('older probe'));
      expect(app.heatmapCalls, hasLength(5));
    });

    test(
      'a failed hot reload is reported, and the app shows its shader',
      () async {
        await controller.showHeatmap();
        app.failReload = true;
        controller.selectVariable(
          controller.statement!.inScope.firstWhere((v) => v.name == 'uv'),
        );
        await pumpEventQueue();
        expect(controller.status, HeatmapStatus.failed);
        expect(controller.statusMessage, contains('Hot reload failed'));
        expect(app.shown, isNull);
      },
    );

    test('the app explains why it refuses', () async {
      app.refuseWith = 'probeMissing';
      await controller.showHeatmap();
      expect(controller.statusMessage, contains('Register it under'));
      app.refuseWith = 'noShaderForAsset';
      await controller.showHeatmap();
      expect(controller.statusMessage, contains('No DebugShader'));
    });

    test(
      'when the probe cannot be written, offers it to paste by hand',
      () async {
        workspace.failWith = WorkspaceError.permissionDenied;
        await controller.showHeatmap();
        expect(controller.status, HeatmapStatus.failed);
        expect(controller.statusMessage, contains('paste the probe'));
        final probe = controller.manualProbe!;

        // The user pastes the probe and hot reloads.
        workspace
          ..failWith = null
          ..files[probeFile] = probe.source;
        await app.hotReload();
        await controller.checkManualProbe();
        expect(controller.status, HeatmapStatus.shown);
        expect(controller.manualProbe, isNull);
      },
    );

    test('changing the range redraws without a reload', () async {
      await controller.showHeatmap();
      await controller.setRange(0.25, 0.75);
      expect(app.reloads, 1);
      expect(app.shown?.min, 0.25);
      expect(app.shown?.max, 0.75);
      expect(controller.status, HeatmapStatus.shown);
    });

    test('picking another value while shown updates the heatmap', () async {
      await controller.showHeatmap();
      final first = controller.shownProbe!.stamp;
      controller.selectLine(lineOf('vec3 col ='));
      await pumpEventQueue();
      expect(controller.status, HeatmapStatus.shown);
      expect(controller.shownProbe?.request.expression, 'col');
      expect(controller.shownProbe!.stamp, greaterThan(first));
      expect(app.reloads, 2);
    });

    test('hiding wins over a heatmap still on its way', () async {
      app.slowAsks = 2;
      final showing = controller.showHeatmap();
      await controller.hideHeatmap();
      await showing;
      expect(controller.status, HeatmapStatus.off);
      expect(app.shown, isNull);
    });
  });

  group('composite values', () {
    int line(String text) => lineOf(text, compositeSource);
    VariableSymbol inScope(String name) =>
        controller.statement!.inScope.firstWhere((v) => v.name == name);

    setUp(() async {
      workspace.files[gradientFile] = compositeSource;
      await connect();
    });

    test('a line that writes an element selects that element', () {
      controller.selectLine(line('weights[2] ='));
      expect(controller.variable?.name, 'weights');
      expect(controller.path, [const IndexSelector(2)]);
      expect(controller.expression, 'weights[2]');
      expect(controller.valueType, GlslType.floatType);
      expect(controller.canShow, isTrue);
    });

    test('a struct goes on to its first drawable field', () {
      controller.selectLine(line('lights[1] ='));
      expect(controller.expression, 'lights[1].position');
      expect(controller.typeAt(0), isA<ArrayType>());
      expect(controller.typeAt(1)?.name, 'Light');
    });

    test('another variable starts at its first drawable part', () {
      controller
        ..selectLine(line('lights[1] ='))
        ..selectVariable(inScope('spin'));
      expect(controller.expression, 'spin[0]');
      expect(controller.valueType, GlslType.vec2);
      controller.selectVariable(inScope('uv'));
      expect(controller.path, isEmpty);
      expect(controller.expression, 'uv');
    });

    test('changing a step picks the first drawable part below it', () {
      controller
        ..selectLine(line('lights[1] ='))
        ..selectStep(1, const FieldSelector('color'));
      expect(controller.expression, 'lights[1].color');
      controller.selectStep(0, const IndexSelector(0));
      expect(controller.expression, 'lights[0].position');

      // Steps that do not apply change nothing.
      controller
        ..selectStep(0, const IndexSelector(5))
        ..selectStep(1, const FieldSelector('radius'))
        ..selectStep(2, const IndexSelector(0));
      expect(controller.expression, 'lights[0].position');
    });

    test('the probe captures the part', () async {
      controller.selectLine(line('lights[1] ='));
      await controller.showHeatmap();
      expect(
        workspace.files[probeFile],
        contains('_dbg_value = vec4(lights[1].position, 0.0, 1.0); }'),
      );
      expect(controller.status, HeatmapStatus.shown);
      expect(controller.shownProbe?.request.expression, 'lights[1].position');
      expect(controller.shownProbe?.valueType, GlslType.vec2);
    });

    test('changing a step while shown updates the heatmap', () async {
      controller.selectLine(line('lights[1] ='));
      await controller.showHeatmap();
      controller.selectStep(1, const FieldSelector('color'));
      await pumpEventQueue();
      expect(controller.status, HeatmapStatus.shown);
      expect(controller.shownProbe?.request.expression, 'lights[1].color');
      expect(app.reloads, 2);
    });
  });

  group('loading probes', () {
    setUp(() async {
      await connect();
      controller.selectLine(lineOf('float d ='));
    });

    test('a probe the app has is not written again', () async {
      await controller.showHeatmap();
      await controller.hideHeatmap();
      await controller.showHeatmap();
      expect(app.reloads, 1);
      expect(controller.status, HeatmapStatus.shown);
    });

    test('a failed hot reload puts back the probe the app still has', () async {
      app.failReload = true;
      await controller.showHeatmap();
      expect(workspace.files[probeFile], '// placeholder\n');

      app.failReload = false;
      await controller.showHeatmap();
      final loaded = workspace.files[probeFile];
      app.failReload = true;
      controller.selectLine(lineOf('vec3 col ='));
      await controller.showHeatmap();
      expect(controller.status, HeatmapStatus.failed);
      expect(workspace.files[probeFile], loaded);
    });
  });

  group('reading a pixel', () {
    setUp(() async {
      await connect();
      controller.selectLine(lineOf('float d ='));
    });

    test('reads the value at typed coordinates', () async {
      await controller.setPixel(12.5, 40);
      expect(controller.pixelStatus, PixelStatus.shown);
      final value = controller.pixelValue!;
      expect(value.components, [0.125, 0.4, 0, 1]);
      expect(value.coord, const Offset(12.5, 40));
      expect(value.probe.request.expression, 'd');
      expect(app.reloads, 1);
      expect(app.pixelCalls.single.instance, isNull);
    });

    test('shares the loaded probe with the heatmap', () async {
      await Future.wait([controller.showHeatmap(), controller.setPixel(1, 2)]);
      expect(app.reloads, 1);
      expect(controller.status, HeatmapStatus.shown);
      expect(controller.pixelStatus, PixelStatus.shown);
      await controller.setPixel(3, 4);
      expect(app.reloads, 1);
    });

    PixelPick at(double x, double y, {int instance = 3}) => PixelPick(
      asset: gradientAsset,
      instance: instance,
      x: x,
      y: y,
      width: 400,
      height: 300,
    );

    test('select mode reads every pixel clicked in the app', () async {
      await controller.setPixelSelectMode(true);
      expect(controller.selectingPixel, isTrue);
      expect(controller.selectTakesClicks, isTrue);
      expect(app.selecting, gradientAsset);

      app.click(at(20.25, 10.75));
      await pumpEventQueue();
      expect(controller.pixelStatus, PixelStatus.shown);
      expect(controller.pixel, const Offset(20.25, 10.75));
      expect(controller.pixelArea, const Size(400, 300));
      expect(app.pixelCalls.single.instance, 3);
      expect(controller.pixelValue?.components.first, 0.2025);

      // It stays on: the next click reads again.
      app.click(at(50, 70, instance: 4));
      await pumpEventQueue();
      expect(controller.pixelValue?.components.first, 0.5);
      expect(app.pixelCalls.last.instance, 4);
      expect(controller.selectingPixel, isTrue);
      expect(app.reloads, 1);
    });

    test('a click off the shader keeps the last value', () async {
      await controller.setPixelSelectMode(true);
      app.click(at(20.25, 10.75));
      await pumpEventQueue();
      app.click(const PixelPick(asset: gradientAsset, reason: 'notOnShader'));
      await pumpEventQueue();
      expect(controller.pixelStatus, PixelStatus.shown);
      expect(controller.pixelValue?.coord, const Offset(20.25, 10.75));
      expect(controller.pixelMessage, contains('not on $gradientAsset'));
    });

    test('select mode turns off from here or from the app', () async {
      await controller.setPixelSelectMode(true);
      await controller.setPixelSelectMode(false);
      expect(controller.selectingPixel, isFalse);
      expect(app.selecting, isNull);

      await controller.setPixelSelectMode(true);
      app.pressDone();
      await pumpEventQueue();
      expect(controller.selectingPixel, isFalse);
    });

    test('says when the app has no overlay to take the clicks', () async {
      app.hasOverlay = false;
      await controller.setPixelSelectMode(true);
      expect(controller.selectingPixel, isTrue);
      expect(controller.selectTakesClicks, isFalse);
    });

    test('picking another value reads it at the same pixel', () async {
      await controller.setPixel(1, 2);
      controller.selectLine(lineOf('vec3 col ='));
      await pumpEventQueue();
      expect(controller.pixelValue?.probe.request.expression, 'col');
      expect(controller.pixelValue?.coord, const Offset(1, 2));
      expect(app.reloads, 2);
    });

    test('waits for the probe to land, and reports refusals', () async {
      app.slowAsks = 2;
      await controller.setPixel(1, 2);
      expect(controller.pixelStatus, PixelStatus.shown);
      expect(app.pixelCalls, hasLength(3));
      app.refuseWith = 'noShaderForAsset';
      await controller.setPixel(1, 2);
      expect(controller.pixelStatus, PixelStatus.failed);
      expect(controller.pixelMessage, contains('No DebugShader'));
    });

    test('another shader starts without a pixel or select mode', () async {
      await controller.setPixel(1, 2);
      await controller.setPixelSelectMode(true);
      await controller.selectShader(gradientAsset);
      expect(controller.pixel, isNull);
      expect(controller.pixelValue, isNull);
      expect(controller.pixelStatus, PixelStatus.off);
      expect(controller.selectingPixel, isFalse);
      expect(app.selecting, isNull);
    });
  });

  test('follows select mode the app is still in after reconnecting', () async {
    app.info = AppInfo(
      protocolVersion: protocolVersion,
      probeAsset: probeAsset,
      shaders: const [gradientAsset],
      pixelSelectAsset: gradientAsset,
    );
    app.selecting = gradientAsset;
    await connect();
    expect(controller.selectingPixel, isTrue);
    controller.selectLine(lineOf('float d ='));
    app.click(const PixelPick(asset: gradientAsset, x: 10, y: 20, instance: 1));
    await pumpEventQueue();
    expect(controller.pixelValue?.components.first, 0.1);
  });

  test('closing the debugger takes the overlay off the app', () async {
    final other = ShaderDebuggerController(
      app: app,
      workspace: workspace,
      retryDelay: Duration.zero,
    )..start();
    app.runtime.value = true;
    await pumpEventQueue();
    other.selectLine(lineOf('float d ='));
    await other.setPixelSelectMode(true);
    expect(app.selecting, gradientAsset);
    other.dispose();
    await pumpEventQueue();
    expect(app.selecting, isNull);
  });

  group('uniforms', () {
    setUp(connect);

    test("lists the shader's uniforms, and which can be overridden", () {
      expect(
        [
          for (final uniform in controller.uniforms)
            (uniform.name, '${uniform.type}', uniform.components),
        ],
        [('uSize', 'vec2', 2), ('uA', 'vec4', 4), ('uB', 'vec4', 4)],
      );
      expect(controller.uniforms[1].componentNames, ['x', 'y', 'z', 'w']);
      expect(const ShaderUniform('m', GlslType.mat2).componentNames, [
        '[0].x',
        '[0].y',
        '[1].x',
        '[1].y',
      ]);
      expect(
        const ShaderUniform('image', GlslType.sampler2D).canOverride,
        isFalse,
      );
      expect(const ShaderUniform('n', GlslType.intType).components, isNull);
    });

    test("reads the app's values", () async {
      await controller.refreshUniforms();
      expect(controller.uniformValues['uA'], [0.1, 0.2, 0.9, 1]);
      expect(controller.uniformOverrides, isEmpty);
    });

    test('overrides a uniform until cleared', () async {
      await controller.setUniformOverride('uA', [0, 1, 0, 1]);
      expect(app.overrides, {
        'uA': [0, 1, 0, 1],
      });
      expect(controller.uniformOverrides['uA'], [0, 1, 0, 1]);
      await controller.clearUniformOverride('uA');
      expect(app.overrides, isEmpty);
      expect(controller.uniformOverrides, isEmpty);
    });

    test('changes made while one is on its way are merged', () async {
      final hold = Completer<void>();
      app.holdOverrides = hold.future;
      final first = controller.setUniformOverride('uA', [0, 0, 0, 1]);
      unawaited(controller.setUniformOverride('uA', [0.5, 0, 0, 1]));
      unawaited(controller.setUniformOverride('uA', [1, 0, 0, 1]));
      // The page shows the latest at once.
      expect(controller.uniformOverrides['uA'], [1, 0, 0, 1]);
      app.holdOverrides = null;
      hold.complete();
      await first;
      expect(
        [for (final (_, values) in app.overrideCalls) values],
        [
          [0, 0, 0, 1],
          [1, 0, 0, 1],
        ],
      );
      expect(app.overrides['uA'], [1, 0, 0, 1]);
    });

    test('a rejected override is reported and dropped', () async {
      await controller.setUniformOverride('uA', [1, 2]);
      expect(
        controller.uniformsError,
        contains('no float uniform uA with 2 components'),
      );
      expect(controller.uniformOverrides, isEmpty);
    });

    test('watching reads the values until stopped', () async {
      final watched = ShaderDebuggerController(
        app: app,
        workspace: workspace,
        uniformRefresh: const Duration(milliseconds: 5),
      )..start();
      addTearDown(watched.dispose);
      await pumpEventQueue();
      watched.watchUniforms(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(watched.uniformValues['uSize'], [400, 300]);
      app.uniformValues['uSize'] = [800, 600];
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(watched.uniformValues['uSize'], [800, 600]);

      watched.watchUniforms(false);
      app.uniformValues['uSize'] = [1, 1];
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(watched.uniformValues['uSize'], [800, 600]);
    });
  });

  test('pixel values that JSON cannot carry arrive as strings', () {
    final answer = PixelAnswer.fromJson({
      'applied': true,
      'value': [0.5, 'NaN', 'Infinity', '-Infinity'],
    });
    expect(answer.value?[0], 0.5);
    expect(answer.value?[1], isNaN);
    expect(answer.value?.sublist(2), [
      double.infinity,
      double.negativeInfinity,
    ]);
    expect(
      PixelAnswer.fromJson({
        'applied': false,
        'reason': 'x',
        'value': <Object>[],
      }).value,
      isNull,
    );
  });
}
