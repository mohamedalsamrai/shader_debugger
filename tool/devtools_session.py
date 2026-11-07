"""A real DevTools session for the example app, as if started from VS Code,
for trying the Shader Debugger extension without an IDE.

Starts (and stops, by PID) only processes it owns:
  1. a Dart Tooling Daemon, with the repo as its IDE workspace root, so the
     extension may read and write files in it;
  2. the example app, with `flutter run -d macos --machine`;
  3. a DevTools server connected to that daemon.

Build the extension first (see CLAUDE.md). When the session is ready, this
prints the extension's URL and writes .dart_tool/shader_debugger_session/
session.json, which test/live_test.dart in packages/shader_debugger_devtools
reads (SHADER_DEBUGGER_LIVE=<that file>). Stop with Ctrl+C, or by creating a
file named `stop` next to session.json. The probe placeholder is restored.

Usage, from the repo root:  python3 tool/devtools_session.py
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.join(ROOT, '.dart_tool', 'shader_debugger_session')
os.makedirs(HERE, exist_ok=True)
EXAMPLE = os.path.join(ROOT, 'packages', 'shader_debugger', 'example')
PROBE = os.path.join(EXAMPLE, 'shaders', '_debug', 'probe.frag')
STOP = os.path.join(HERE, 'stop')
SESSION = os.path.join(HERE, 'session.json')
LOG = open(os.path.join(HERE, 'session.log'), 'w', buffering=1)

placeholder = open(PROBE).read()
options_before = {p: os.path.exists(p) for p in [
    os.path.join(ROOT, 'devtools_options.yaml'),
    os.path.join(EXAMPLE, 'devtools_options.yaml'),
]}
children = []


def log(*parts):
    print(*parts, file=LOG)


def start(args, cwd=None):
    proc = subprocess.Popen(args, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    children.append(proc)
    lines = queue.Queue()

    def pump():
        for line in proc.stdout:
            lines.put(line)
            if 'trusted_client_secret' in line:
                continue  # Never log the daemon's secret.
            log('[%s] %s' % (os.path.basename(args[0]) + ' ' + args[1], line.rstrip()[:300]))
    threading.Thread(target=pump, daemon=True).start()
    return proc, lines


def wait_json(lines, predicate, timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        try:
            line = lines.get(timeout=1).strip()
        except queue.Empty:
            continue
        if line.startswith('[') and line.endswith(']'):
            line = line[1:-1]
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if predicate(message):
            return message
    raise TimeoutError('timed out')


try:
    # 1. Dart Tooling Daemon, with the repo as the workspace root.
    dtd, dtd_lines = start(['dart', 'tooling-daemon', '--machine'])
    details = wait_json(dtd_lines, lambda m: 'tooling_daemon_details' in m)['tooling_daemon_details']
    dtd_uri = details['uri']
    roots = subprocess.run(
        ['dart', '--packages=' + os.path.join(ROOT, '.dart_tool', 'package_config.json'),
         os.path.join(ROOT, 'tool', 'set_dtd_roots.dart'), dtd_uri, ROOT],
        input=details['trusted_client_secret'] + '\n', capture_output=True, text=True)
    log('set_roots:', roots.stdout.strip(), roots.stderr.strip()[:300])

    # 2. The example app.
    app, app_lines = start(['flutter', 'run', '-d', 'macos', '--machine'], cwd=EXAMPLE)
    debug_port = wait_json(app_lines, lambda m: m.get('event') == 'app.debugPort')
    vm_uri = debug_port['params']['wsUri']
    app_id = debug_port['params']['appId']
    wait_json(app_lines, lambda m: m.get('event') == 'app.started')

    # 3. DevTools, connected to our DTD.
    devtools, devtools_lines = start(['dart', 'devtools', '--machine', '--no-launch-browser',
                                      '--port=0', '--dtd-uri=' + dtd_uri])
    started = wait_json(devtools_lines, lambda m: m.get('event') == 'server.started')['params']
    base = 'http://%s:%s' % (started['host'], started['port'])
    from urllib.parse import quote
    extension_url = '%s/shader_debugger?uri=%s' % (base, quote(vm_uri, safe=''))
    json.dump({
        'dtd_uri': dtd_uri,
        'devtools': base,
        'vm_uri': vm_uri,
        'extension_url': extension_url,
        'roots': roots.stdout.strip(),
    }, open(SESSION, 'w'), indent=2)
    log('session ready')
    print('Shader Debugger extension: ' + extension_url)
    print('Session file: ' + SESSION)
    print('Stop with Ctrl+C.', flush=True)

    deadline = time.time() + 45 * 60
    while not os.path.exists(STOP) and time.time() < deadline:
        time.sleep(1)
except KeyboardInterrupt:
    pass
finally:
    try:
        if 'app_id' in globals():
            app.stdin.write(json.dumps([{'id': 1, 'method': 'app.stop', 'params': {'appId': app_id}}]) + '\n')
            app.stdin.flush()
            time.sleep(3)
    except Exception as error:  # noqa: BLE001
        log('stop failed:', error)
    for proc in reversed(children):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
    open(PROBE, 'w').write(placeholder)
    for path, existed in options_before.items():
        if not existed and os.path.exists(path):
            print('DevTools created ' + path)
    if os.path.exists(STOP):
        os.remove(STOP)
    log('stopped')
    print('Stopped.')
