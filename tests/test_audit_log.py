"""Чтение локального аудита и отбор текущего испытания без доступа к кластеру."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
MOCK_KUBECTL = '''#!/usr/bin/env python3
import os
import sys
assert sys.argv[1:4] == ['get', 'namespace', 'pmi-' + os.environ['PMI_AUDIT_NUMBER']]
if os.environ['PMI_AUDIT_MODE'] != 'missing_namespace_time':
    print(os.environ['PMI_AUDIT_START'])
'''
MOCK_SUDO = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
assert sys.argv[1:] == ['cat', os.environ['AUDIT_FILE']]
if os.environ['PMI_AUDIT_MODE'] == 'read_error':
    print('cat: журнал недоступен', file=sys.stderr)
    sys.exit(1)
print(Path(os.environ['PMI_AUDIT_FIXTURE']).read_text(), end='')
'''


class AuditLogTest(unittest.TestCase):
    def run_check(self, number, mode):
        with tempfile.TemporaryDirectory(prefix='.audit-test-', dir=PROJECT) as directory:
            directory = Path(directory)
            for name, code in (('kubectl', MOCK_KUBECTL), ('sudo', MOCK_SUDO)):
                executable = directory / name
                executable.write_text(code)
                executable.chmod(0o755)
            now = datetime.now(timezone.utc)
            timestamp = (now - timedelta(seconds=10)).isoformat(timespec='microseconds').replace('+00:00', 'Z')
            start = (now - timedelta(seconds=20)).isoformat(timespec='seconds').replace('+00:00', 'Z')
            old_timestamp = (now - timedelta(hours=1)).isoformat(timespec='microseconds').replace('+00:00', 'Z')
            events = []
            for verb in ('create', 'get', 'patch', 'delete'):
                events.append({'kind': 'Event', 'stage': 'ResponseComplete', 'auditID': 'current-' + verb,
                               'requestReceivedTimestamp': timestamp, 'verb': verb,
                               'objectRef': {'namespace': 'pmi-' + str(number), 'resource': 'configmaps', 'name': 'audit-marker'},
                               'responseStatus': {'code': 200}})
            events.append(dict(events[1], auditID='current-denied', responseStatus={'code': 403},
                               impersonatedUser={'username': 'system:serviceaccount:pmi-' + str(number) + ':observer'}))
            old_events = [dict(event, requestReceivedTimestamp=old_timestamp, auditID='old-' + event['auditID']) for event in events]
            if mode == 'missing_delete':
                events = [event for event in events if event['verb'] != 'delete']
            if mode == 'missing_denial':
                events = [event for event in events if event['responseStatus']['code'] != 403]
            if mode == 'only_old':
                events = []
            if mode == 'wrong_namespace':
                for event in events:
                    event['objectRef'] = dict(event['objectRef'], namespace='another-test')
            fixture = directory / 'audit.log'
            fixture.write_text('\n'.join(json.dumps(event) for event in events + old_events) + '\n')
            if mode == 'malformed':
                fixture.write_text('это не JSON\n')
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                               AUDIT_FILE=str(fixture), PMI_AUDIT_FIXTURE=str(fixture),
                               PMI_AUDIT_NUMBER=str(number), PMI_AUDIT_MODE=mode, PMI_AUDIT_START=start)
            script = PROJECT / str(number) / '02-check.sh'
            if mode == 'default':
                # Подменяем только системный путь, чтобы тест никогда не читал настоящий журнал.
                code = script.read_text()
                self.assertIn('AUDIT_FILE=/var/log/kube-audit/audit.log', code)
                isolated_script = directory / 'check.sh'
                isolated_script.write_text(code.replace('AUDIT_FILE=/var/log/kube-audit/audit.log',
                                                        'AUDIT_FILE=' + shlex.quote(str(fixture))))
                script = isolated_script
                environment.pop('AUDIT_FILE')
            if mode in ('sudo', 'read_error'):
                environment['AUDIT_FILE'] = str(directory / 'unreadable.log')
            return subprocess.run(['bash', str(script)], env=environment, capture_output=True, text=True, timeout=10)

    def test_only_current_complete_events_are_accepted(self):
        modes = ('correct', 'missing_delete', 'missing_denial', 'only_old', 'wrong_namespace',
                 'malformed', 'missing_namespace_time', 'read_error')
        for number in (34, 56):
            for mode in modes:
                with self.subTest(number=number, mode=mode):
                    result = self.run_check(number, mode)
                    if mode == 'correct':
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn('УСПЕХ:', result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertNotIn('УСПЕХ:', result.stdout)
                    self.assertNotIn('old-current-', result.stdout)

    def test_default_source_and_sudo_reading(self):
        for number in (34, 56):
            for mode in ('default', 'sudo'):
                with self.subTest(number=number, mode=mode):
                    result = self.run_check(number, mode)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('УСПЕХ:', result.stdout)
                    self.assertNotIn('old-current-', result.stdout)


if __name__ == '__main__':
    unittest.main()
