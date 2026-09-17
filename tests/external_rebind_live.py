"""Live M4 test of production display-rebind with independent external cleanup.

Requires an open lid and two awake, extended external monitors. It temporarily
turns off the built-in under OpenClam's normal guardian, rebinds one external,
then verifies that both external modes and the original built-in mode return.
This is configuration evidence, not optical verification or M3 unlock evidence.
"""
import json
import pathlib
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
tmp = root / '.tmp'
tmp.mkdir(exist_ok=True)
app = root / 'build/OpenClam.app/Contents/MacOS'
binary = app / 'OpenClam'
link = app / 'display-link'
helper = app / 'display-rebind'
parent = tmp / 'display-rebind-live-parent'
trial_log = tmp / 'external-rebind-live-trial.log'
rebind_log = tmp / 'external-rebind-live-helper.log'


def snapshot():
    return json.loads(subprocess.check_output([str(link)], timeout=8))


def records(path):
    result = []
    for line in path.read_text().splitlines():
        if line.startswith('{'):
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:  # The writer may not have finished this line.
                pass
    return result


def awake_external(state):
    return {d['id']: d for d in state['displays']
            if not d['builtin'] and d['active'] and not d['asleep']}


def original_restored(state, before):
    original = next(d for d in before['displays'] if d['builtin'] and d['active'])
    builtin = [d for d in state['displays'] if d['builtin'] and d['active'] and not d['asleep']]
    return (len(builtin) == 1 and builtin[0]['mode'] == original['mode']
            and awake_external(state) == awake_external(before))


# Compile the independent parent before performing any display operation.
subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=15.0',
                '-fobjc-arc', '-O2', '-Wall', '-Wextra',
                str(root / 'tests/display_rebind_live.m'), '-framework', 'Foundation',
                '-framework', 'CoreGraphics', '-framework', 'IOKit', '-o', str(parent)], check=True)
for executable in (binary, link, helper):
    assert executable.is_file(), f'Missing built production executable: {executable.name}'
before = snapshot()
assert before.get('physicalLidClosed') is False, 'Keep the physical lid open'
assert len(awake_external(before)) >= 2, 'Requires two awake external monitors'
assert len([d for d in before['displays'] if d['builtin'] and d['active'] and not d['asleep']]) == 1

failure = None
live = None
with trial_log.open('w') as trial_output, rebind_log.open('w') as helper_output:
    owner = subprocess.Popen([str(binary), 'trial', '60'], stdout=trial_output, stderr=trial_output)
    try:
        deadline = time.monotonic() + 12
        while not any(r.get('phase') == 'off' for r in records(trial_log)):
            if owner.poll() is not None:
                raise RuntimeError('Owned trial ended before off phase')
            if time.monotonic() >= deadline:
                raise RuntimeError('No guarded off phase observed')
            time.sleep(0.1)
        off = snapshot()
        externals = awake_external(off)
        assert len(externals) >= 2 and not any(d['builtin'] and d['active'] for d in off['displays'])
        assert externals == awake_external(before), 'Normal off changed an external display'
        targets = [(f['matchedDisplayID'], f['registryID']) for f in off['framebuffers']
                   if f.get('matchedDisplayID') in externals
                   and sum(g.get('matchedDisplayID') == f['matchedDisplayID'] for g in off['framebuffers']) == 1]
        assert targets, 'No unique framebuffer mapping for an external display'
        display_id, registry_id = sorted(targets)[0]
        live = subprocess.Popen([str(parent), str(helper), str(registry_id), str(display_id)],
                                stdout=helper_output, stderr=helper_output)
        try:
            live.wait(timeout=20)
        except subprocess.TimeoutExpired:
            # Signal only our parent; it reaps its production helper and enables
            # the independently pinned external before returning.
            live.terminate()
            live.wait(timeout=10)
            raise RuntimeError('Independent rebind parent exceeded its deadline')
        events = records(rebind_log)
        assert live.returncode == 0, 'Production rebind or independent cleanup check failed'
        assert any(r.get('phase') == 'disabled_settled' for r in events), 'No real disabled state observed'
        assert any(r.get('phase') == 'enabled_settled' for r in events), 'No settled enabled state observed'
        result = next(r for r in events if r.get('phase') == 'live_parent_complete')
        assert result['passed'] and result['targetActiveAwakeOriginalMode'] and result['otherDisplaysUnchanged']
    except BaseException as error:
        failure = error
    finally:
        if live is not None and live.poll() is None:
            live.terminate()
            try:
                live.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Do not kill the independent recovery parent. Still release
                # the owned trial so its separate built-in guardian can recover.
                failure = RuntimeError(f'Rebind recovery parent {live.pid} is still running; inspect {rebind_log}')
        # The trial's independent guardian sees EOF and restores the built-in.
        # Never terminate another OpenClam instance or an unowned process.
        if owner.poll() is None:
            owner.terminate()
        owner.wait(timeout=25)
        deadline = time.monotonic() + 15
        restored = False
        while time.monotonic() < deadline:
            if original_restored(snapshot(), before):
                restored = True
                break
            time.sleep(0.5)
        assert restored, f'Original display configuration not restored; inspect {trial_log}'
if failure:
    raise failure
print('PASS: production external disable/enable settled; original external modes unchanged; built-in original mode restored. Pixels not verified.')
print(f'Logs: {trial_log} and {rebind_log}')
