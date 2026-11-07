// Sets the IDE workspace roots on a Dart Tooling Daemon, as VS Code does.
// Used by tool/devtools_session.py.
// Usage: dart set_dtd_roots.dart <dtd-uri> <root-dir>   (secret on stdin)
import 'dart:convert';
import 'dart:io';

import 'package:dtd/dtd.dart';

Future<void> main(List<String> args) async {
  final secret = stdin.transform(utf8.decoder).transform(const LineSplitter());
  final value = await secret.first;
  final dtd = await DartToolingDaemon.connect(Uri.parse(args[0]));
  await dtd.setIDEWorkspaceRoots(value, [Uri.directory(args[1])]);
  final roots = await dtd.getIDEWorkspaceRoots();
  print('roots: ${roots.ideWorkspaceRoots}');
  await dtd.close();
}
