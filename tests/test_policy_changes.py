"""Различаем контроль авторизации, блокировку PATCH и ошибку предварительного GET."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


PROJECT = Path(__file__).resolve().parents[1]
MOCK_KUBECTL = r'''#!/usr/bin/env python3
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
actor = None
for argument in list(args):
    if argument.startswith('--as='):
        actor = argument.split('=', 1)[1]
        args.remove(argument)
namespace = ''
if '-n' in args:
    index = args.index('-n')
    namespace = args[index + 1]
    del args[index:index + 2]
command, resource, name = args[:3]
state_path = Path(os.environ['PMI_POLICY_STATE'])
state = json.loads(state_path.read_text())
objects = state['objects']
mode = os.environ['PMI_POLICY_MODE']
number = os.environ['PMI_POLICY_NUMBER']


def allowed(verb):
    if actor is None:
        return True
    group = 'rbac.authorization.k8s.io' if resource == 'role' else 'deckhouse.io'
    plural = 'roles' if resource == 'role' else 'securitypolicies'
    for binding in objects:
        kind = binding['kind']
        if kind not in ('RoleBinding', 'ClusterRoleBinding'):
            continue
        if kind == 'RoleBinding' and binding['metadata'].get('namespace') != namespace:
            continue
        subjects = binding['subjects']
        matches = any(actor == 'system:serviceaccount:' + subject['namespace'] + ':' + subject['name'] for subject in subjects)
        if not matches:
            continue
        reference = binding['roleRef']
        role = next(item for item in objects if item['kind'] == reference['kind'] and item['metadata']['name'] == reference['name'])
        for rule in role['rules']:
            if group not in rule['apiGroups'] or plural not in rule['resources']:
                continue
            if name not in rule.get('resourceNames', [name]):
                continue
            if verb in rule['verbs']:
                return True
    return False


def denied(verb):
    plural = 'roles' if resource == 'role' else 'securitypolicies'
    print(f'Error from server (Forbidden): {plural} "{name}" is forbidden: User "{actor}" cannot {verb} resource "{plural}"', file=sys.stderr)


def save():
    state_path.write_text(json.dumps(state))


if command == 'get' and resource == 'namespace':
    print(os.environ['PMI_POLICY_START'])
    sys.exit(0)
if command == 'delete':
    assert resource in ('rolebinding', 'clusterrolebinding')
    assert name in ('editor', 'pmi-37-editor')
    kind = 'RoleBinding' if resource == 'rolebinding' else 'ClusterRoleBinding'
    if mode != 'revocation_ignored':
        state['objects'] = [item for item in objects if not (item['kind'] == kind and item['metadata']['name'] == name)]
    state['revoked'] = True
    save()
    print('binding deleted')
    sys.exit(0)
kind = 'Role' if resource == 'role' else 'SecurityPolicy'
obj = next(item for item in objects if item['kind'] == kind and item['metadata']['name'] == name)
# Имитируем предварительный GET самого kubectl patch, а не только HTTP PATCH.
if not allowed('get'):
    denied('get')
    sys.exit(1)
if command == 'get':
    if '-o' not in args:
        print(json.dumps(obj))
    elif resource == 'role':
        print(' '.join(obj['rules'][0]['verbs']))
    else:
        print(str(obj['spec']['policies']['allowHostNetwork']).lower())
    sys.exit(0)
assert command == 'patch'
if mode == 'api_error' and actor and actor.endswith(':observer'):
    print('Unable to connect to the server', file=sys.stderr)
    sys.exit(1)
if mode == 'admin_failed' and actor is None:
    sys.exit(1)
permitted = allowed('patch') or mode == 'unexpected_allow'
patch = json.loads(args[args.index('-p') + 1])
if permitted or mode == 'changed_on_deny':
    if resource == 'role':
        obj['rules'] = patch['rules']
    else:
        obj['spec']['policies'].update(patch['spec']['policies'])
if number == '36':
    plural = 'roles' if resource == 'role' else 'securitypolicies'
    stamp = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    event = {'kind': 'Event', 'stage': 'ResponseComplete', 'verb': 'patch',
             'requestReceivedTimestamp': stamp, 'auditID': plural + '-' + actor,
             'objectRef': {'apiGroup': 'rbac.authorization.k8s.io' if resource == 'role' else 'deckhouse.io',
                           'resource': plural, 'name': name, 'namespace': namespace},
             'impersonatedUser': {'username': actor},
             'responseStatus': {'code': 200 if permitted else 403},
             'annotations': {'authorization.k8s.io/decision': 'allow' if permitted else 'forbid'}}
    if mode == 'wrong_actor':
        event['impersonatedUser']['username'] = 'someone-else'
    if mode == 'wrong_decision':
        event['annotations']['authorization.k8s.io/decision'] = 'allow'
    if mode == 'old_audit':
        event['requestReceivedTimestamp'] = '2000-01-01T00:00:00Z'
    if not (mode == 'missing_audit' and resource == 'securitypolicy' and not permitted):
        with open(os.environ['AUDIT_FILE'], 'a') as stream:
            stream.write(json.dumps(event) + '\n')
save()
if not permitted:
    denied('patch')
    sys.exit(1)
print('policy patched')
'''


class PolicyChangesTest(unittest.TestCase):
    def run_scenario(self, number, mode):
        preparation = (PROJECT / str(number) / '01-prepare.sh').read_text()
        manifest = re.search(r"<<'YAML'\n(.*?)\nYAML", preparation, re.S).group(1)
        objects = list(yaml.safe_load_all(manifest))
        if mode == 'no_get':
            reader = 'observer' if number == 36 else 'reader'
            for obj in objects:
                if obj['kind'] in ('Role', 'ClusterRole') and obj['metadata']['name'] in (reader, f'pmi-{number}-{reader}'):
                    obj['rules'][0]['verbs'] = []
        with tempfile.TemporaryDirectory(prefix='.policy-test-', dir=PROJECT) as location:
            directory = Path(location)
            executable = directory / 'kubectl'
            executable.write_text(MOCK_KUBECTL)
            executable.chmod(0o755)
            state_file = directory / 'state.json'
            state_file.write_text(json.dumps({'objects': objects, 'revoked': False}))
            audit_file = directory / 'audit.log'
            audit_file.write_text('')
            start = datetime.now(timezone.utc) - timedelta(seconds=30)
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                               PMI_POLICY_STATE=str(state_file), PMI_POLICY_MODE=mode,
                               PMI_POLICY_NUMBER=str(number), PMI_POLICY_START=start.isoformat(),
                               AUDIT_FILE=str(audit_file))
            result = subprocess.run(['bash', str(PROJECT / str(number) / '02-check.sh')],
                                    env=environment, capture_output=True, text=True, timeout=10)
            state = json.loads(state_file.read_text())
            return result, state

    def test_authorization_requires_both_policy_audit_records(self):
        for mode in ('correct', 'no_get', 'unexpected_allow', 'api_error', 'missing_audit', 'wrong_actor', 'wrong_decision', 'old_audit'):
            with self.subTest(mode=mode):
                result, _ = self.run_scenario(36, mode)
                if mode == 'correct':
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('УСПЕХ:', result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn('УСПЕХ:', result.stdout)
                if mode == 'no_get':
                    self.assertIn('cannot get resource', result.stderr)

    def test_revocation_blocks_changes_but_preserves_reading(self):
        for mode in ('correct', 'no_get', 'revocation_ignored', 'changed_on_deny', 'admin_failed'):
            with self.subTest(mode=mode):
                result, state = self.run_scenario(37, mode)
                if mode == 'correct':
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('УСПЕХ:', result.stdout)
                    role = next(obj for obj in state['objects'] if obj['kind'] == 'Role' and obj['metadata']['name'] == 'target')
                    policy = next(obj for obj in state['objects'] if obj['kind'] == 'SecurityPolicy')
                    self.assertEqual(role['rules'][0]['verbs'], ['get'])
                    self.assertFalse(policy['spec']['policies']['allowHostNetwork'])
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn('УСПЕХ:', result.stdout)
                if mode == 'no_get':
                    self.assertTrue(state['revoked'])
                    self.assertIn('cannot get resource', result.stderr)


if __name__ == '__main__':
    unittest.main()
