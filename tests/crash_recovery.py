"""Deliberately kill only our own trial process after it has disconnected the panel."""
import json
import pathlib
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = root / 'build/OpenClam.app/Contents/MacOS/OpenClam'
log_path = root / '.tmp/crash-recovery.log'
with log_path.open('w') as log:
    owner = subprocess.Popen([str(binary), 'trial', '30'], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 15
        disconnected = False
        while time.monotonic() < deadline:
            lines = log_path.read_text().splitlines()
            if any(line.startswith('{') and json.loads(line).get('phase') == 'off' for line in lines):
                disconnected = True
                break
            if owner.poll() is not None:
                raise RuntimeError('Trial exited before off phase')
            time.sleep(0.5)
        if not disconnected:
            raise RuntimeError('No confirmed off phase; no crash injected')
        owner.kill()
        owner.wait(timeout=5)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = json.loads(subprocess.check_output([str(binary), 'status']))
            awake = any(d['builtin'] and d['active'] and not d['asleep'] for d in state['displays'])
            for line in log_path.read_text().splitlines():
                if line.startswith('{'):
                    record = json.loads(line)
                    if record.get('guardianRestore') and record.get('reason') == 'owner_exited':
                        assert awake
                        print('PASS: independent guardian restored inner display after SIGKILL of its owner.')
                        raise SystemExit(0)
            time.sleep(0.5)
        raise RuntimeError('Guardian recovery not confirmed; use helper on or reopen lid')
    finally:
        if owner.poll() is None:
            owner.terminate()
            owner.wait(timeout=5)
