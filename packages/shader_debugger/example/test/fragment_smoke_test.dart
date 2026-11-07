import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FragmentProgram renders under flutter test', () async {
    final program = await ui.FragmentProgram.fromAsset('shaders/gradient.frag');
    final shader = program.fragmentShader();
    shader.getUniformVec2('uSize').set(4, 4);
    shader.getUniformVec4('uA').set(1, 0, 0, 1);
    shader.getUniformVec4('uB').set(0, 0, 1, 1);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..shader = shader);
    final image = await recorder.endRecording().toImage(4, 4);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    print('pixel(0,0) rgba = ${bytes!.buffer.asUint8List().sublist(0, 4)}');
    final f = recorder.toString();
    expect(f, isNotNull);
    final img2 = await (ui.PictureRecorder()..let()).toString();
  });
}
extension on ui.PictureRecorder { void let() {} }
