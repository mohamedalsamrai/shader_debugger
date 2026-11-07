/// Compiles generated probes with impellerc, the compiler the Flutter tool
/// uses. Skipped when impellerc cannot be found next to `flutter`.
library;

import 'dart:io';

import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// The target flags the Flutter tool passes for macOS and for Android
/// (`build_system/tools/shader_compiler.dart`).
const targets = {
  'macOS': ['--sksl', '--runtime-stage-metal'],
  'Android': [
    '--sksl',
    '--runtime-stage-gles',
    '--runtime-stage-gles3',
    '--runtime-stage-vulkan',
  ],
};

void main() {
  final impellerc = _findImpellerc();
  final skip = impellerc == null
      ? 'impellerc not found next to the flutter on PATH'
      : false;

  final probes = <String, Probe Function()>{
    'gradient: d (scalar)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.dStatement, variable: f.d),
        stamp: 1,
      );
    },
    'gradient: uv (rg)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.uvStatement, variable: f.uv),
        stamp: 2,
      );
    },
    'gradient: col[1] (path)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(
          statement: f.colStatement,
          variable: f.col,
          path: const [IndexSelector(1)],
        ),
        stamp: 3,
      );
    },
    'gradient: fragColor (rgba, wrapped expression)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.outputStatement, variable: f.fragColor),
        stamp: 4,
      );
    },
    'branchy: a before return (jump)': () {
      final f = BranchyFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.returnStatement, variable: f.a),
        stamp: 5,
      );
    },
    'branchy: a after the if (control)': () {
      final f = BranchyFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.ifStatement, variable: f.a),
        stamp: 6,
      );
    },
    'branchy: a += b (compound assignment)': () {
      final f = BranchyFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.compound, variable: f.a),
        stamp: 7,
      );
    },
  };

  late Directory temp;
  setUpAll(() => temp = Directory.systemTemp.createTempSync('probe_compile'));
  tearDownAll(() => temp.deleteSync(recursive: true));

  for (final MapEntry(key: name, value: build) in probes.entries) {
    for (final MapEntry(key: target, value: flags) in targets.entries) {
      test('$name compiles for $target', skip: skip, () {
        final probe = build();
        final input = File('${temp.path}/probe_${probe.stamp}.frag')
          ..writeAsStringSync(probe.source);
        final out = '${temp.path}/probe_${probe.stamp}_$target';
        final result = Process.runSync(impellerc!.path, [
          ...flags,
          '--iplr',
          '--sl=$out.iplr',
          '--spirv=$out.spirv',
          '--input=${input.path}',
          '--input-type=frag',
          '--include=${temp.path}',
          '--include=${impellerc.parent.path}/shader_lib',
        ]);
        expect(
          result.exitCode,
          0,
          reason:
              '${result.stdout}\n${result.stderr}\n--- probe ---\n'
              '${probe.source}',
        );
      });
    }
  }
}

File? _findImpellerc() {
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'flutter',
  ]);
  if (which.exitCode != 0) return null;
  final flutter = File((which.stdout as String).trim().split('\n').first)
      .resolveSymbolicLinksSync();
  final engine = Directory(
    '${File(flutter).parent.path}/cache/artifacts/engine',
  );
  final host = Platform.isMacOS
      ? 'darwin-x64'
      : Platform.isWindows
      ? 'windows-x64'
      : 'linux-x64';
  final impellerc = File(
    '${engine.path}/$host/impellerc${Platform.isWindows ? '.exe' : ''}',
  );
  return impellerc.existsSync() ? impellerc : null;
}
