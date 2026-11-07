/// The [DebuggedApp] and [Workspace] that DevTools provides. This is the only
/// file that touches the `serviceManager` and `dtdManager` globals.
library;

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:dtd/dtd.dart';
import 'package:flutter/foundation.dart';
import 'package:json_rpc_2/json_rpc_2.dart' show RpcException;
import 'package:shader_debugger_core/protocol.dart';

import 'ports.dart';

final class DevToolsDebuggedApp implements DebuggedApp {
  @override
  ValueListenable<bool> get hasRuntime => serviceManager.serviceExtensionManager
      .hasServiceExtension(ServiceExtensions.getInfo);

  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, String> args = const {},
  ]) async {
    final response = await serviceManager.callServiceExtensionOnMainIsolate(
      method,
      args: args,
    );
    return response.json ?? const {};
  }

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
  Future<void> pickPixel(String asset) =>
      _call(ServiceExtensions.pickPixel, {'asset': asset});

  @override
  Future<void> cancelPick() => _call(ServiceExtensions.cancelPick);

  /// DevTools' service manager already listens to the Extension stream.
  @override
  Stream<PixelPick> get pixelPicks {
    final service = serviceManager.service;
    if (service == null) return const Stream.empty();
    return service.onExtensionEvent
        .where((event) => event.extensionKind == ServiceEvents.pixelPicked)
        .map(
          (event) => PixelPick.fromJson(
            Map<String, Object?>.from(event.extensionData?.data ?? const {}),
          ),
        );
  }

  @override
  Future<void> hotReload() => serviceManager.performHotReload();

  @override
  Future<Uri?> rootLibrary() async {
    final uri = await serviceManager.mainIsolateRootLibraryUriAsString();
    return uri == null ? null : Uri.parse(uri);
  }
}

final class DtdWorkspace implements Workspace {
  DartToolingDaemon _dtd() =>
      dtdManager.connection.value ??
      (throw const WorkspaceException(
        WorkspaceError.unavailable,
        'DevTools is not connected to the Dart Tooling Daemon.',
      ));

  @override
  Future<String> read(Uri file) async {
    try {
      return (await _dtd().readFileAsString(file)).content ?? '';
    } on RpcException catch (error) {
      throw _translate(error);
    }
  }

  @override
  Future<void> write(Uri file, String contents) async {
    try {
      await _dtd().writeFileAsString(file, contents);
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
