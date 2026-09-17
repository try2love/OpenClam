"""Kill our guardian while its off helper is alive; owner must reap the group before recovery."""
import json
import os
import pathlib
import signal
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = root / 'build/OpenClam.app/Contents/MacOS/OpenClam'
path = root / '.tmp/routing-guardian-crash.log'

def children(pid):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines()
    return [(int(p), command) for line in rows if len(parts := line.strip().split(None, 2)) == 3
            for p, parent, command in [parts] if int(parent) == pid]

with path.open('w') as log:
    owner = subprocess.Popen([str(binary), 'routing-trial', '45'], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 20
        killed = False
        while time.monotonic() < deadline:
            for guardian, command in children(owner.pid):
                if '--routing-guard ' in command:
                    for helper, helper_command in children(guardian):
                        if helper_command.startswith(str(binary.parent / 'display-helper') + ' off '):
                            # Only this test's descendant, never the user's app.
                            assert os.getpgid(helper) == guardian, 'Mutator escaped guardian process group'
                            os.kill(guardian, signal.SIGKILL)
                            killed = True
                            break
                if killed:
                    break
            if killed:
                break
            if owner.poll() is not None:
                raise RuntimeError('Owner exited before intended crash')
            time.sleep(0.1)
        assert killed, 'No owned off helper observed'
        owner.wait(timeout=40)
        records = [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
        assert any(r.get('stage') == 'verified' and r.get('restored') for r in records)
        assert not any(r.get('requestedState') == 'closed' for r in records), 'Late close after guardian death'
        state = json.loads(subprocess.check_output([str(binary), 'status'], timeout=8))
        assert any(d['builtin'] and d['active'] and not d['asleep'] for d in state['displays'])
        try:
            os.kill(helper, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('Original mutator still exists after recovery')
        print('PASS: guardian SIGKILL during off helper; isolated descendants stopped; builtin mode restored.')
    finally:
        if owner.poll() is None:
            owner.terminate()
            owner.wait(timeout=5)
