"""Проверяем остановку подготовки до мутаций при неподходящем стенде."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
MOCK_KUBECTL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
with open(os.environ['PMI_TEST_LOG'], 'a') as log:
    log.write(json.dumps(arguments) + '\n')
if arguments[0] in ('create', 'apply', 'patch', 'label', 'delete'):
    # Останавливаем положительный сценарий на первой мутации, не выполняя её.
    sys.exit(90)
mode = os.environ['PMI_TEST_MODE']
if arguments[0] == 'explain':
    if arguments[1] == os.environ.get('PMI_TEST_FIELD'):
        print('error: field does not exist', file=sys.stderr)
        sys.exit(1)
    print('FIELD: ' + arguments[1])
    sys.exit(0)
resource = arguments[arguments.index('get') + 1]
if resource == 'module':
    if mode == 'module_missing':
        print('Error from server (NotFound)', file=sys.stderr)
        sys.exit(1)
    print('Unavailable' if mode == 'module_disabled' else 'Ready')
elif resource == 'csidriver':
    if mode == 'csi_missing':
        print('Error from server (NotFound)', file=sys.stderr)
        sys.exit(1)
    print('csidriver.storage.k8s.io/secrets-store.csi.deckhouse.io')
elif resource == 'crd':
    print('["JSON", "Text"]' if mode == 'syslog_missing' else '["JSON", "Syslog"]')
elif resource == 'validatingwebhookconfigurations':
    print('other.webhook' if mode == 'gatekeeper_missing' else 'validation.gatekeeper.sh')
elif resource == 'moduleconfig':
    print('spec: {enabled: true}')
elif resource == 'pods':
    if 'component=etcd' in arguments:
        print('' if mode == 'etcd_missing' else 'pod/etcd-master0')
    else:
        print('pod/kube-apiserver-master0 pod/kube-apiserver-master1')
elif resource.startswith('pod/kube-apiserver'):
    if mode == 'audit_missing' and resource.endswith('master1'):
        print('kube-apiserver --secure-port=6443')
    else:
        print('kube-apiserver --audit-policy-file=/audit/policy --audit-log-path=/audit/log')
elif resource == 'backupstoragelocation':
    if any('.spec.accessMode' in item for item in arguments):
        print('ReadOnly' if mode == 'storage_readonly' else 'ReadWrite')
    else:
        print('Unavailable' if mode == 'storage_unavailable' else 'Available')
elif resource == 'ingressnginxcontrollers.deckhouse.io':
    print('' if mode == 'controller_missing' else 'ingressnginxcontroller/test')
elif resource == 'ingressnginxcontroller/test':
    if any('.spec.ingressClass' in item for item in arguments):
        print('nginx')
    else:
        print('false' if mode == 'sidecar_disabled' else 'true')
elif resource == 'ingress':
    print('hubble.example.test')
else:
    print('Неожиданный запрос в локальном тесте: ' + str(arguments), file=sys.stderr)
    sys.exit(99)
'''
MOCK_VELERO = r'''#!/usr/bin/env python3
import os
import sys
if sys.argv[1:] != ['version', '--client-only']:
    sys.exit(99)
if os.environ['PMI_TEST_MODE'] == 'velero_missing':
    print('velero: command not found', file=sys.stderr)
    sys.exit(127)
print('Client: тестовая версия')
'''


class PreparePreconditionsTest(unittest.TestCase):
    def run_prepare(self, number, mode='ready', field=''):
        with tempfile.TemporaryDirectory(prefix='.prepare-test-', dir=PROJECT) as location:
            directory = Path(location)
            for name, source in (('kubectl', MOCK_KUBECTL), ('velero', MOCK_VELERO)):
                executable = directory / name
                executable.write_text(source, encoding='utf-8')
                executable.chmod(0o755)
            certificate = directory / 'test.pem'
            certificate.write_text('Тест читаемости файла, не реальный сертификат.\n')
            log = directory / 'commands.jsonl'
            environment = dict(os.environ)
            environment.update({
                'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                'PMI_TEST_LOG': str(log), 'PMI_TEST_MODE': mode, 'PMI_TEST_FIELD': field,
                'APP_HOST': 'app.example.test', 'EXTERNAL_HOST': 'external.example.test',
                'INGRESS_CLASS': 'nginx', 'TLS_CERT': str(certificate), 'TLS_KEY': str(certificate),
                'SYSLOG_ADDRESS': 'syslog.example.test:514',
            })
            result = subprocess.run(
                ['bash', str(PROJECT / str(number) / '01-prepare.sh')],
                env=environment, text=True, capture_output=True,
            )
            commands = []
            if log.exists():
                for line in log.read_text().splitlines():
                    commands.append(json.loads(line))
            mutations = [command for command in commands
                         if command[0] in ('create', 'apply', 'patch', 'label', 'delete')]
            return result, commands, mutations

    def test_ready_reaches_first_creation(self):
        for number in (5, 34, 36, 37, 41, 48, 51, 54, 56, 58):
            with self.subTest(number=number):
                result, _, mutations = self.run_prepare(number)
                self.assertEqual(result.returncode, 90, result.stdout + result.stderr)
                self.assertEqual(len(mutations), 1)

    def test_module_missing_or_disabled_stops_before_creation(self):
        for number in (5, 36, 37, 41, 48, 51, 54):
            for mode in ('module_missing', 'module_disabled'):
                with self.subTest(number=number, mode=mode):
                    result, _, mutations = self.run_prepare(number, mode)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('ОШИБКА:', result.stdout)
                    self.assertEqual(mutations, [])

    def test_each_project_field_is_required_in_correct_version(self):
        fields = {
            'projecttemplate.spec.parametersSchema.openAPIV3Schema': 'v1alpha1',
            'projecttemplate.spec.resourcesTemplate': 'v1alpha1',
            'projecttemplate.status.ready': 'v1alpha1',
            'project.spec.projectTemplateName': 'v1alpha2',
            'project.spec.parameters': 'v1alpha2',
            'project.status.state': 'v1alpha2',
        }
        for field, version in fields.items():
            with self.subTest(field=field):
                result, commands, mutations = self.run_prepare(51, field=field)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(field, result.stdout)
                self.assertEqual(mutations, [])
                request = next(command for command in commands
                               if command[:2] == ['explain', field])
                self.assertIn('--api-version=deckhouse.io/' + version, request)

    def test_missing_integrations_stop_before_creation(self):
        cases = ((5, 'csi_missing'), (48, 'syslog_missing'), (48, 'etcd_missing'),
                 (54, 'gatekeeper_missing'), (34, 'audit_missing'), (56, 'audit_missing'),
                 (58, 'storage_unavailable'), (58, 'storage_readonly'),
                 (58, 'velero_missing'), (41, 'controller_missing'), (41, 'sidecar_disabled'))
        for number, mode in cases:
            with self.subTest(number=number, mode=mode):
                result, _, mutations = self.run_prepare(number, mode)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('ОШИБКА:', result.stdout)
                self.assertEqual(mutations, [])


if __name__ == '__main__':
    unittest.main()
