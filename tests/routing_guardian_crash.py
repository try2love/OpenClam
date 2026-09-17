"""Kill our guardian with layout-off pending; owner must reap its helper group.

An isolated app copy replaces display-helper with a native stop/exec fixture.
Stopping only layout-off makes the crash point observable even when the real
layout operation finishes faster than ps can sample it. No user app is changed.
"""
import json
import os
import pathlib
import signal
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
tmp = root / '.tmp'
tmp.mkdir(exist_ok=True)
fixture = pathlib.Path(tempfile.mkdtemp(prefix='routing-guardian-crash-', dir=tmp))
app = fixture / 'OpenClam.app'
shutil.copytree(root / 'build/OpenClam.app', app)
binary = app / 'Contents/MacOS/OpenClam'
helper_binary = binary.parent / 'display-helper'
helper_binary.rename(helper_binary.with_name('display-helper.original'))
subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=15.0',
                '-O2', '-Wall', '-Wextra', str(root / 'tests/routing_pending_helper.c'),
                '-o', str(helper_binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(helper_binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
path = root / '.tmp/routing-guardian-crash.log'
diagnostics = root / '.tmp/routing-guardian-crash-diagnostics'
environment = {**os.environ, 'OPENCLAM_DIAGNOSTICS_DIR': str(diagnostics)}
previous_sessions = set(diagnostics.glob('routing-session-*.jsonl'))

def children(pid):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines()
    return [(int(p), command) for line in rows if len(parts := line.strip().split(None, 2)) == 3
            for p, parent, command in [parts] if int(parent) == pid]

def records():
    sessions = sorted(set(diagnostics.glob('routing-session-*.jsonl')) - previous_sessions)
    content = path.read_text() + (sessions[-1].read_text() if sessions else '')
    return [json.loads(line) for line in content.splitlines(keepends=True)
            if line.startswith('{') and line.endswith('\n')]

with path.open('w') as log:
    owner = subprocess.Popen([str(binary), 'routing-trial', '45'], stdout=log, stderr=log, env=environment)
    helper = guardian = owned_group = None
    try:
        deadline = time.monotonic() + 20
        killed = False
        while time.monotonic() < deadline:
            pending = [r for r in records() if r.get('testPendingMutator')]
            if pending:
                marker = pending[-1]
                helper, guardian = marker['pid'], marker['parentPID']
                assert any(pid == guardian and command.startswith(str(binary) + ' --routing-guard ')
                           for pid, command in children(owner.pid)), 'Marker guardian is not our descendant'
                assert any(pid == helper and command.startswith(str(helper_binary) + ' layout-off ')
                           for pid, command in children(guardian)), 'Marker helper is not our fixture'
                # The marker precedes SIGSTOP. Wait for the stopped state, so
                # getpgid/kill cannot race the short production layout command.
                state = subprocess.check_output(['ps', '-o', 'state=', '-p', str(helper)], text=True).strip()
                if state.startswith('T'):
                    assert marker['processGroup'] == guardian and os.getpgid(helper) == guardian, \
                        'Mutator escaped guardian process group'
                    owned_group = guardian
                    os.kill(guardian, signal.SIGKILL)
                    killed = True
            if killed:
                break
            if owner.poll() is not None:
                raise RuntimeError('Owner exited before intended crash')
            time.sleep(0.05)
        assert killed, 'No owned stopped layout-off helper observed before the bounded guardian wait ended'
        owner.wait(timeout=40)
        events = records()
        assert any(r.get('stage') == 'verified' and r.get('restored') for r in events)
        assert not any(r.get('requestedState') == 'closed' for r in events), 'Late close after guardian death'
        state = json.loads(subprocess.check_output([str(binary), 'status'], timeout=8))
        assert any(d['builtin'] and d['active'] and not d['asleep'] for d in state['displays'])
        try:
            os.kill(helper, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('Original mutator still exists after recovery')
        print('PASS: guardian SIGKILL with pending layout-off helper; isolated descendants stopped; builtin mode restored.')
        print(f'Fixture: {fixture}')
    finally:
        # Ownership and the isolated group were checked before the crash. If an
        # assertion failed, stop any remaining descendants before owner cleanup.
        if owned_group is not None:
            try:
                os.killpg(owned_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # A failed ownership/group assertion must not leave our stopped fixture
        # behind. Signal only the PID whose command still names this unique copy.
        if helper is not None:
            try:
                command = subprocess.check_output(['ps', '-o', 'command=', '-p', str(helper)], text=True).strip()
                if command.startswith(str(helper_binary) + ' layout-off '):
                    os.kill(helper, signal.SIGKILL)
            except (ProcessLookupError, subprocess.CalledProcessError):
                pass
        if owner.poll() is None:
            owner.terminate()
            owner.wait(timeout=40)
