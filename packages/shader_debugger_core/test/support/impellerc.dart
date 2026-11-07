/// Runs impellerc, the shader compiler the Flutter tool uses, on test probes.
library;

import 'dart:io';

/// The target flags the Flutter tool passes for macOS and for Android
/// (`build_system/tools/shader_compiler.dart`).
const impellercTargets = {
  'macOS': ['--sksl', '--runtime-stage-metal'],
  'Android': [
    '--sksl',
    '--runtime-stage-gles',
    '--runtime-stage-gles3',
    '--runtime-stage-vulkan',
  ],
};

/// impellerc from the Flutter SDK on PATH, or null if there is none.
final File? impellerc = _findImpellerc();

/// Why impellerc tests are skipped, or false when they can run.
Object get skipWithoutImpellerc => impellerc == null
    ? 'impellerc not found next to the flutter on PATH'
    : false;

/// The Flutter SDK root, from the `flutter` on PATH.
final Directory? flutterRoot = _findFlutterRoot();

/// Compiles [source] for [target] (a key of [impellercTargets]), writing
/// files into [directory] under [name].
Future<ProcessResult> compileShader(
  String source, {
  required Directory directory,
  required String name,
  String target = 'macOS',
}) async {
  final compiler = impellerc!;
  final input = File('${directory.path}/$name.frag')..writeAsStringSync(source);
  final out = '${directory.path}/${name}_$target';
  return Process.run(compiler.path, [
    ...impellercTargets[target]!,
    '--iplr',
    '--sl=$out.iplr',
    '--spirv=$out.spirv',
    '--input=${input.path}',
    '--input-type=frag',
    '--include=${directory.path}',
    '--include=${compiler.parent.path}/shader_lib',
  ]);
}

Directory? _findFlutterRoot() {
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'flutter',
  ]);
  if (which.exitCode != 0) return null;
  final flutter = File((which.stdout as String).trim().split('\n').first.trim())
      .resolveSymbolicLinksSync();
  return File(flutter).parent.parent;
}

File? _findImpellerc() {
  final root = _findFlutterRoot();
  if (root == null) return null;
  final host = Platform.isMacOS
      ? 'darwin-x64'
      : Platform.isWindows
      ? 'windows-x64'
      : 'linux-x64';
  final file = File(
    '${root.path}/bin/cache/artifacts/engine/$host/impellerc'
    '${Platform.isWindows ? '.exe' : ''}',
  );
  return file.existsSync() ? file : null;
}
