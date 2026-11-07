/// The example gallery, set up for recording the README's GIFs: time comes
/// from outside, and `ext.media.*` service extensions let
/// `tool/readme_media.py` move a mouse pointer, click, and capture frames
/// from the app's own layer tree (no screen recording). Debug only.
///
/// Run from packages/shader_debugger/example:
/// `flutter run -d macos -t ../../../tool/media/media_app.dart`
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shader_debugger_example/main.dart';

/// The logical size of the recorded area: the app, at a README-friendly
/// size, so overlays (select mode's banner) stay in frame.
const stageSize = Size(760, 520);

final _time = ValueNotifier<double>(0);
final _stage = GlobalKey();

/// The synthesized mouse.
const _mouse = 77;
var _mouseAdded = false;
var _pointer = 1000;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final shaders = await ExampleShader.loadAll();
  _register('time', (p) async {
    _time.value = double.parse(p['t']!);
    return {};
  });
  _register('layout', (p) async => _layout(shaders));
  // Pointer events hit test, which needs the tree laid out: a change just
  // made (select mode's overlay, a heatmap) may still await its frame.
  _register('hover', (p) async {
    await WidgetsBinding.instance.endOfFrame;
    _hover(_offset(p));
    return {};
  });
  _register('click', (p) async {
    await WidgetsBinding.instance.endOfFrame;
    _click(_offset(p));
    return {};
  });
  _register('capture', _capture);
  runApp(
    ColoredBox(
      color: const Color(0xFF202124),
      child: Center(
        child: ClipRect(
          child: SizedBox.fromSize(
            key: _stage,
            size: stageSize,
            child: ExampleApp(shaders: shaders, time: _time),
          ),
        ),
      ),
    ),
  );
}

void _register(
  String name,
  Future<Map<String, Object?>> Function(Map<String, String>) handler,
) {
  developer.registerExtension('ext.media.$name', (method, parameters) async {
    try {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(await handler(parameters)),
      );
    } on Object catch (error) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '$error',
      );
    }
  });
}

Offset _offset(Map<String, String> p) =>
    Offset(double.parse(p['x']!), double.parse(p['y']!));

Map<String, double> _rect(RenderBox box) {
  final origin = box.localToGlobal(Offset.zero);
  return {
    'left': origin.dx,
    'top': origin.dy,
    'width': box.size.width,
    'height': box.size.height,
  };
}

/// Where the stage and each shader's painted area are, in global logical
/// coordinates.
Map<String, Object?> _layout(List<ExampleShader> shaders) {
  final painted = <String, Map<String, double>>{};
  void visit(Element element) {
    final widget = element.widget;
    if (widget is CustomPaint && widget.painter is ShaderPainter) {
      final asset = (widget.painter! as ShaderPainter).shader.asset;
      painted[asset] = _rect(element.renderObject! as RenderBox);
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return {
    'stage': _rect(_stage.currentContext!.findRenderObject()! as RenderBox),
    'ratio':
        RendererBinding.instance.renderViews.first.flutterView.devicePixelRatio,
    'painted': painted,
  };
}

void _hover(Offset position) {
  final binding = GestureBinding.instance;
  if (!_mouseAdded) {
    _mouseAdded = true;
    binding.handlePointerEvent(
      PointerAddedEvent(
        position: position,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
      ),
    );
  }
  binding.handlePointerEvent(
    PointerHoverEvent(
      position: position,
      kind: PointerDeviceKind.mouse,
      device: _mouse,
    ),
  );
}

void _click(Offset position) {
  _hover(position);
  final binding = GestureBinding.instance;
  final pointer = ++_pointer;
  binding
    ..handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        position: position,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        buttons: kPrimaryButton,
      ),
    )
    ..handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        position: position,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
      ),
    );
}

/// The region `left`, `top`, `width`, `height` (global logical) of the next
/// frame, as a base64 PNG at the device's pixel ratio.
Future<Map<String, Object?>> _capture(Map<String, String> p) async {
  await WidgetsBinding.instance.endOfFrame;
  final view = RendererBinding.instance.renderViews.first;
  final ratio = view.flutterView.devicePixelRatio;
  double at(String key) => double.parse(p[key]!) * ratio;
  final image = await (view.debugLayer! as OffsetLayer).toImage(
    Rect.fromLTWH(at('left'), at('top'), at('width'), at('height')),
  );
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return {'png': base64Encode(png!.buffer.asUint8List())};
  } finally {
    image.dispose();
  }
}
