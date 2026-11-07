import 'package:flutter_test/flutter_test.dart';
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
}
