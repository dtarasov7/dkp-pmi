"""Отличаем тайм-аут curl от ошибок доступа и недоступности HTTP-сервера."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SUCCESS_MESSAGE = 'Сетевой отказ воспроизведён.'
MOCK_KUBECTL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
if arguments[:1] == ['-n']:
    arguments = arguments[2:]
state_path = Path(os.environ['PMI_NETWORK_STATE'])
state = json.loads(state_path.read_text())
mode = os.environ['PMI_NETWORK_MODE']
command = arguments[0]
if command == 'get':
    print('192.0.2.10')
elif command == 'create':
    manifest = sys.stdin.read()
    assert 'kind: NetworkPolicy' in manifest
    state['blocked'] = True
    state_path.write_text(json.dumps(state))
elif command == 'exec':
    assert arguments[1] == 'client'
    assert 'curl' in arguments and '--noproxy' in arguments
    if state['blocked'] and mode == 'delayed_policy':
        state['attempts'] = state.get('attempts', 0) + 1
        state_path.write_text(json.dumps(state))
        if state['attempts'] < 3:
            print('pmi-ok')
            sys.exit(0)
    if not state['blocked'] or mode == 'unexpected_allow':
        print('pmi-ok')
    else:
        # Текст намеренно не содержит английских признаков тайм-аута wget/curl.
        print('Не удалось получить ответ за отведённое время.', file=sys.stderr)
        codes = {'api_error': 1, 'connection_refused': 7, 'http_error': 22}
        sys.exit(codes.get(mode, 28))
elif command == 'wait':
    sys.exit(1 if mode == 'server_unready' else 0)
else:
    sys.exit(99)
'''


class NetworkRequestsTest(unittest.TestCase):
    def test_only_timeout_with_healthy_server_is_accepted(self):
        modes = ('correct', 'api_error', 'connection_refused', 'http_error',
                 'delayed_policy', 'server_unready', 'unexpected_allow')
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='.network-test-', dir=PROJECT) as directory:
                directory = Path(directory)
                executable = directory / 'kubectl'
                executable.write_text(MOCK_KUBECTL)
                executable.chmod(0o755)
                sleep = directory / 'sleep'
                sleep.write_text('#!/bin/sh\nexit 0\n')
                sleep.chmod(0o755)
                state_file = directory / 'state.json'
                state_file.write_text(json.dumps({'blocked': False}))
                environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                                   PMI_NETWORK_STATE=str(state_file), PMI_NETWORK_MODE=mode)
                result = subprocess.run(['bash', str(PROJECT / '53/02-check.sh')], env=environment,
                                        capture_output=True, text=True, timeout=20)
                expected_code = 0 if mode in ('correct', 'delayed_policy') else 1
                self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
                if expected_code == 0:
                    self.assertIn(SUCCESS_MESSAGE, result.stdout)
                    self.assertIn('Код запроса: 28', result.stdout)
                else:
                    self.assertNotIn(SUCCESS_MESSAGE, result.stdout)


if __name__ == '__main__':
    unittest.main()
