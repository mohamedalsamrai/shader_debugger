"""End-to-end check of heatmap mode's app side, through the real Flutter tool.

Runs the example app on macOS with `flutter run --machine`, writes probes into
shaders/_debug/probe.frag, hot reloads, and drives the ext.shader_debugger.*
service extensions the way the DevTools extension will. The probe is the
instrumenter's golden output (example/test/probes/gradient_capture_d.frag).
The placeholder probe is restored at the end.

Usage, from the repo root:
    python3 tool/e2e_heatmap.py [SCREENSHOT_DIR]

With SCREENSHOT_DIR, it also saves the app window before and after the
heatmap is shown (needs the Screen Recording permission). Exits non-zero if a
check fails.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLE = os.path.join(ROOT, 'packages', 'shader_debugger', 'example')
PROBE = os.path.join(EXAMPLE, 'shaders', '_debug', 'probe.frag')
GOLDEN = os.path.join(EXAMPLE, 'test', 'probes', 'gradient_capture_d.frag')
ASSET = 'shaders/gradient.frag'
SHOTS = sys.argv[1] if len(sys.argv) > 1 else None

placeholder = open(PROBE).read()
golden = open(GOLDEN).read()
failures = []


def check(label, ok, detail):
    print(('PASS  ' if ok else 'FAIL  ') + label + ': ' + str(detail))
    if not ok:
        failures.append(label)


proc = subprocess.Popen(
    ['flutter', 'run', '-d', 'macos', '--machine'],
    cwd=EXAMPLE, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, text=True, bufsize=1)
events = queue.Queue()


def pump():
    for line in proc.stdout:
        line = line.strip()
        if line.startswith('[{') and line.endswith('}]'):
            events.put(json.loads(line)[0])


threading.Thread(target=pump, daemon=True).start()
next_id = [0]
app_id = None


def wait(predicate, timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        try:
            message = events.get(timeout=1)
        except queue.Empty:
            continue
        if predicate(message):
            return message
    raise TimeoutError('no answer from flutter run')


def call(method, params, timeout=300):
    next_id[0] += 1
    request_id = next_id[0]
    proc.stdin.write(json.dumps([{'id': request_id, 'method': method, 'params': params}]) + '\n')
    proc.stdin.flush()
    return wait(lambda m: m.get('id') == request_id, timeout)


def extension(name, **params):
    message = call('app.callServiceExtension', {
        'appId': app_id,
        'methodName': 'ext.shader_debugger.' + name,
        'params': {key: str(value) for key, value in params.items()},
    })
    result = message.get('result') or {}
    return {k: v for k, v in result.items() if k not in ('type', 'method')}


def hot_reload_with(probe_source):
    open(PROBE, 'w').write(probe_source)
    return call('app.restart', {'appId': app_id, 'fullRestart': False, 'pause': False}).get('result', {})


def show(stamp, tries=10):
    """Shows the heatmap, retrying while the reloaded probe lands."""
    for attempt in range(1, tries + 1):
        result = extension('showHeatmap', asset=ASSET, stamp=stamp)
        if result.get('applied'):
            return result, attempt
        time.sleep(0.3)
    return result, tries


def screenshot(name):
    if not SHOTS:
        return
    os.makedirs(SHOTS, exist_ok=True)
    script = ('ObjC.import("CoreGraphics");'
              'var l=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0)));'
              'var w=l.filter(function(x){return x.kCGWindowOwnerName=="shader_debugger_example"'
              '&&x.kCGWindowLayer==0;})[0];w?w.kCGWindowNumber:"";')
    window = subprocess.run(['osascript', '-l', 'JavaScript', '-e', script],
                            capture_output=True, text=True).stdout.strip()
    path = os.path.join(SHOTS, name)
    if window and subprocess.run(['screencapture', '-x', '-o', '-l' + window, path]).returncode == 0:
        print('      screenshot: ' + path)
    else:
        print('      (no screenshot: window not found or no Screen Recording permission)')


try:
    app_id = wait(lambda m: m.get('event') == 'app.started')['params']['appId']
    time.sleep(2)

    info = extension('getInfo')
    check('getInfo lists the example shader', info.get('shaders') == [ASSET] and info.get('heatmap') is None, info)
    result = extension('showHeatmap', asset=ASSET, stamp=1)
    check('the placeholder probe has no stamp', result.get('reason') == 'probeNotLoaded', result)
    screenshot('0_original.png')

    reload = hot_reload_with(golden)
    check('hot reload with the stamp-1 probe', reload.get('code') == 0, reload)
    result, attempts = show(1)
    check('heatmap shown for stamp 1', result.get('applied'), '%s after %d attempt(s)' % (result, attempts))
    time.sleep(1)
    screenshot('1_heatmap_d.png')

    reload = hot_reload_with(golden.replace('_dbg_stamp_1', '_dbg_stamp_2'))
    check('hot reload with a stamp-2 probe', reload.get('code') == 0, reload)
    result, attempts = show(2)
    check('heatmap shown for stamp 2', result.get('applied'), '%s after %d attempt(s)' % (result, attempts))
    heatmap = extension('getInfo').get('heatmap') or {}
    check('getInfo reports the heatmap', heatmap.get('stamp') == 2, heatmap)

    broken = golden.replace('_dbg_stamp_1', '_dbg_stamp_3').replace('length(', 'lenth(')
    reload = hot_reload_with(broken)
    check('a probe that does not compile fails the reload', reload.get('code') != 0, reload)
    result = extension('showHeatmap', asset=ASSET, stamp=3)
    check('its stamp never loads', result.get('reason') == 'probeNotLoaded', result)
    result = extension('showHeatmap', asset=ASSET, stamp=2)
    check('the previous probe is still loaded', result.get('applied'), result)

    extension('hideHeatmap')
    heatmap = extension('getInfo').get('heatmap')
    check('hideHeatmap clears the heatmap', heatmap is None, heatmap)
finally:
    open(PROBE, 'w').write(placeholder)
    if app_id:
        try:
            call('app.stop', {'appId': app_id}, timeout=30)
        except Exception as error:  # noqa: BLE001
            print('could not stop the app: %s' % error)
    proc.terminate()
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()

print('\n%d check(s) failed' % len(failures) if failures else '\nAll checks passed.')
sys.exit(1 if failures else 0)
