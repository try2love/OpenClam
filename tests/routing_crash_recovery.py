"""Kill only our own owner during apply or after activation; observe real recovery."""
import json
import pathlib
import subprocess
import sys
import time

phase = sys.argv[1]
assert phase in ('applying', 'active')
root = pathlib.Path(__file__).resolve().parents[1]
binary = root / 'build/OpenClam.app/Contents/MacOS/OpenClam'
path = root / f'.tmp/routing-crash-{phase}.log'

def records():
    return [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]

with path.open('w') as log:
    owner = subprocess.Popen([str(binary), 'routing-trial', '45'], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            content = path.read_text()
            ready = ('layout: built-in display disconnected' in content if phase == 'applying'
                     else any(r.get('routingGuardianPreview') for r in records()))
            if ready:
                break
            if owner.poll() is not None:
                raise RuntimeError('Owner exited before intended crash point')
            time.sleep(0.1)
        else:
            raise RuntimeError('Crash point not reached')
        owner.kill()
        owner.wait(timeout=5)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            restored = [r for r in records() if r.get('routingRestore')]
            if restored:
                state = json.loads(subprocess.check_output([str(binary), 'status'], timeout=8))
                assert any(d['builtin'] and d['active'] and not d['asleep'] for d in state['displays'])
                requests = [r['requestedState'] for r in records() if 'requestedState' in r]
                assert requests[-1] == 'open', requests
                if phase == 'active':
                    assert requests == ['closed', 'open'], requests
                    assert restored[-1]['reason'] == 'owner_exited'
                else:
                    assert requests == ['open'], 'A close was submitted after owner death'
                print(f'PASS: owner SIGKILL during {phase}; final driver request open; builtin awake.')
                break
            time.sleep(0.25)
        else:
            raise RuntimeError('Independent recovery not confirmed')
    finally:
        if owner.poll() is None:
            owner.terminate()
            owner.wait(timeout=5)
