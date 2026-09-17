"""Validate a real routing-trial log. M4 success is not M3 unlock evidence."""
import json
import sys

records = [json.loads(s) for s in open(sys.argv[1]) if s.startswith('{')]
phases = {r['phase']: r for r in records if 'phase' in r}
before, active, restored = [phases[p]['snapshot'] for p in ('before', 'routing_active', 'restored')]
external = lambda s: {d['id'] for d in s['displays'] if not d['builtin'] and d['active']}
assert active['displayQueryReturn'] == 0
assert active['clamshell']['AppleClamshellState'] is False
assert len(external(active)) >= 2
assert not any(d['builtin'] and d['active'] for d in active['displays'])
assert external(before).issubset(external(active))
assert any(d['builtin'] and d['active'] and not d['asleep'] for d in restored['displays'])
assert phases['restored']['verifiedLayoutAndWake']
requests = [r for r in records if 'requestedState' in r]
assert [r['requestedState'] for r in requests] == ['closed', 'open']
assert requests[0]['registryID'] == requests[1]['registryID']
assert all(r['result'] == 'submitted_not_verified' for r in requests)
assert any(r.get('routingRestore') and r.get('reason') == 'trial_expired' for r in records)
print('PASS: driver close/open submitted in order; two externals active with lid open; builtin restored.')
print(f'Additional external IDs activated: {sorted(external(active) - external(before))}')
