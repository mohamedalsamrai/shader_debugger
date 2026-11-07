/// Runs the debugger's controller against a real session: the example app
/// under `flutter run`, and a Dart Tooling Daemon whose workspace root is the
/// repo, as VS Code sets it up. Only the DevTools glue (devtools_ports.dart
/// and the page itself) is not exercised.
///
/// Skipped unless SHADER_DEBUGGER_LIVE names a JSON file with `dtd_uri` and
/// `vm_uri`; tool/devtools_session.py writes one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dtd/dtd.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' show RpcException;
import 'package:shader_debugger_core/protocol.dart';
import 'package:shader_debugger_devtools/src/controller.dart';
import 'package:shader_debugger_devtools/src/ports.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main() {
  final sessionFile = Platform.environment['SHADER_DEBUGGER_LIVE'];

  test(
    'heatmap through DTD, hot reload and the runtime',
    skip: sessionFile == null ? 'set SHADER_DEBUGGER_LIVE to run' : false,
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final session = jsonDecode(
        File(sessionFile!).readAsStringSync(),
      ) as Map<String, Object?>;
      final dtd = await DartToolingDaemon.connect(
        Uri.parse(session['dtd_uri']! as String),
      );
      final service = await vmServiceConnectUri(session['vm_uri']! as String);
      addTearDown(() async {
        await dtd.close();
        await service.dispose();
      });
      final app = await VmDebuggedApp.connect(service);
      final workspace = DtdTestWorkspace(dtd);
      final controller = ShaderDebuggerController(
        app: app,
        workspace: workspace,
      )..start();
      addTearDown(controller.dispose);

      Future<void> until(bool Function() done, String what) async {
        for (var i = 0; i < 200 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(done(), isTrue, reason: 'timed out waiting for $what');
      }

      Future<Map<String, Object?>> info() async =>
          (await service.callServiceExtension(
            ServiceExtensions.getInfo,
            isolateId: app.isolateId,
          )).json!;

      // Connects, finds the example's directory, reads and analyzes the shader.
      await until(() => controller.analysis != null, 'the shader');
      expect(
        controller.appRoot?.path,
        endsWith('/packages/shader_debugger/example/'),
      );
      expect(controller.asset, 'shaders/gradient.frag');

      int line(String text) => controller.analysis!.statements
          .firstWhere((s) => s.span.text.startsWith(text))
          .line;

      // Pick d and show it: writes the probe through DTD, hot reloads through
      // the Flutter tool, and has the runtime swap the probe in.
      controller.selectLine(line('float d'));
      await controller.showHeatmap();
      expect(
        controller.status,
        HeatmapStatus.shown,
        reason: controller.statusMessage,
      );
      final first = controller.shownProbe!.stamp;
      expect((await info())['heatmap'], containsPair('stamp', first));

      // A new range needs no reload.
      await controller.setRange(0.2, 0.8);
      expect((await info())['heatmap'], containsPair('max', 0.8));

      // Picking another value while shown updates the heatmap live.
      controller.selectLine(line('vec3 col'));
      await until(
        () =>
            controller.status == HeatmapStatus.shown &&
            controller.shownProbe!.stamp != first,
        'the col heatmap',
      );
      expect(controller.shownProbe!.request.expression, 'col');

      // DTD refuses files outside the workspace roots.
      await expectLater(
        workspace.write(Uri.file('/tmp/shader_debugger_outside.txt'), 'x'),
        throwsA(
          isA<WorkspaceException>().having(
            (e) => e.error,
            'error',
            WorkspaceError.permissionDenied,
          ),
        ),
      );

      await controller.hideHeatmap();
      expect((await info())['heatmap'], isNull);
    },
  );
}

/// [DebuggedApp] over a raw VM service connection, like DevTools' own.
class VmDebuggedApp implements DebuggedApp {
  VmDebuggedApp._(this.service, this.isolateId, this._reloadMethod);

  static Future<VmDebuggedApp> connect(VmService service) async {
    final vm = await service.getVM();
    final isolateId = vm.isolates!.first.id!;
    // The Flutter tool registers its hot reload as a service; subscribing
    // to the Service stream replays the registrations.
    final reload = Completer<String>();
    final subscription = service.onServiceEvent.listen((event) {
      if (event.kind == EventKind.kServiceRegistered &&
          event.service == 'reloadSources' &&
          !reload.isCompleted) {
        reload.complete(event.method!);
      }
    });
    await service.streamListen(EventStreams.kService);
    final method = await reload.future.timeout(const Duration(seconds: 10));
    await subscription.cancel();
    return VmDebuggedApp._(service, isolateId, method);
  }

  final VmService service;
  final String isolateId;
  final String _reloadMethod;

  @override
  final ValueListenable<bool> hasRuntime = ValueNotifier(true);

  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, String> args = const {},
  ]) async =>
      (await service.callServiceExtension(
        method,
        isolateId: isolateId,
        args: args,
      )).json ??
      const {};

  @override
  Future<AppInfo> getInfo() async =>
      AppInfo.fromJson(await _call(ServiceExtensions.getInfo));

  @override
  Future<ProbeAnswer> showHeatmap({
    required String asset,
    required int stamp,
    required double min,
    required double max,
  }) async {
    final json = await _call(ServiceExtensions.showHeatmap, {
      'asset': asset,
      'stamp': '$stamp',
      'min': '$min',
      'max': '$max',
    });
    return ProbeAnswer(
      applied: json['applied'] == true,
      reason: json['reason'] as String?,
    );
  }

  @override
  Future<void> hideHeatmap() => _call(ServiceExtensions.hideHeatmap);

  @override
  Future<PixelAnswer> readPixel({
    required String asset,
    required int stamp,
    required double x,
    required double y,
    int? instance,
  }) async => PixelAnswer.fromJson(
    await _call(ServiceExtensions.readPixel, {
      'asset': asset,
      'stamp': '$stamp',
      'x': '$x',
      'y': '$y',
      if (instance != null) 'instance': '$instance',
    }),
  );

  @override
  Future<bool> setPixelSelectMode({
    required bool enabled,
    String? asset,
  }) async {
    final json = await _call(ServiceExtensions.setPixelSelectMode, {
      'enabled': '$enabled',
      'asset': ?asset,
    });
    return json['overlay'] == true;
  }

  Stream<Map<String, Object?>> _events(String kind) => service.onExtensionEvent
      .where((event) => event.extensionKind == kind)
      .map(
        (event) =>
            Map<String, Object?>.from(event.extensionData?.data ?? const {}),
      );

  @override
  Stream<PixelPick> get pixelPicks =>
      _events(ServiceEvents.pixelPicked).map(PixelPick.fromJson);

  @override
  Stream<void> get pixelSelectModeExits =>
      _events(ServiceEvents.pixelSelectMode);

  @override
  Future<void> hotReload() async {
    await service.callMethod(_reloadMethod, isolateId: isolateId);
  }

  @override
  Future<Uri?> rootLibrary() async {
    final isolate = await service.getIsolate(isolateId);
    final root = isolate.rootLib?.uri;
    if (root == null) return null;
    final resolved = await service.lookupResolvedPackageUris(isolateId, [root]);
    final file = resolved.uris?.first;
    return file == null ? null : Uri.parse(file);
  }
}

/// The same DTD calls as DtdWorkspace, with an explicit connection.
class DtdTestWorkspace implements Workspace {
  DtdTestWorkspace(this.dtd);

  final DartToolingDaemon dtd;

  @override
  Future<String> read(Uri file) async {
    try {
      return (await dtd.readFileAsString(file)).content ?? '';
    } on RpcException catch (error) {
      throw _translate(error);
    }
  }

  @override
  Future<void> write(Uri file, String contents) async {
    try {
      await dtd.writeFileAsString(file, contents);
    } on RpcException catch (error) {
      throw _translate(error);
    }
  }

  static WorkspaceException _translate(RpcException error) =>
      WorkspaceException(switch (error.code) {
        RpcErrorCodes.kPermissionDenied => WorkspaceError.permissionDenied,
        RpcErrorCodes.kFileDoesNotExist => WorkspaceError.notFound,
        _ => WorkspaceError.other,
      }, error.message);
}
