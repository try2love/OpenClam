"""Check a real trial log; no mock is counted as hardware success."""
import json
import sys

with open(sys.argv[1]) as handle:
    records = [json.loads(line) for line in handle if line.startswith('{')]
phases = {r['phase']: r for r in records if 'phase' in r}
before, off, restored = [phases[p]['snapshot'] for p in ('before', 'off', 'restored')]
assert before['clamshell']['AppleClamshellState'] is False
assert off['clamshell']['AppleClamshellState'] is False, 'This is not a fake-clamshell trial'
assert before['activeExternalCount'] >= 1
external = lambda s: {d['id'] for d in s['displays'] if not d['builtin'] and d['active']}
assert external(before) == external(off) == external(restored)
assert any(d['builtin'] and d['active'] for d in before['displays'])
assert not any(d['builtin'] and d['active'] for d in off['displays'])
assert any(d['builtin'] and d['active'] and not d['asleep'] for d in restored['displays'])
assert phases['restored']['verifiedLayoutAndWake']
print('PASS: inner display removed and restored; external display IDs preserved; lid state remained open.')
print('Not verified here: optical backlight state, physical cable removal, M3 resource reassignment.')
