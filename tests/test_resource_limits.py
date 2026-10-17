"""Проверки сценария ресурсов и shell-проверки CPU без обращения к Kubernetes."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
CHECK_SCRIPT = PROJECT / '21/02-check.sh'
CPU_CODE = re.search(r"<<'SHELL'\n(.*?)\nSHELL", CHECK_SCRIPT.read_text(), re.S).group(1)
SUCCESS_MESSAGE = 'УСПЕХ: проверены replicas 2 → 3 → 1'
MOCK_KUBECTL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
if arguments[:1] == ['-n']:
    arguments = arguments[2:]
state_path = Path(os.environ['PMI21_STATE'])
state = json.loads(state_path.read_text())
mode = os.environ['PMI21_MODE']
command = arguments[0]
if command == 'scale':
    replicas_argument = next(item for item in arguments if item.startswith('--replicas='))
    state['replicas'] = int(replicas_argument.split('=')[1])
    state_path.write_text(json.dumps(state))
    print('deployment scaled')
elif command == 'rollout':
    print('deployment successfully rolled out')
elif command == 'exec':
    program = sys.stdin.read()
    assert 'stress-ng --cpu 1' in program
    if mode == 'cpu_failed':
        print('ОШИБКА: throttling не подтверждён.')
        sys.exit(1)
    print('Подставной ответ CPU для проверки обработки результата.')
elif command == 'create':
    manifest = sys.stdin.read()
    assert 'kind: Job' in manifest and 'name: memory-limit' in manifest
    state['memory_created'] = True
    state_path.write_text(json.dumps(state))
    print('job created')
elif command == 'wait':
    if '--for=condition=Failed' in arguments and mode == 'job_not_failed':
        sys.exit(1)
    if any('.status.replicas' in item for item in arguments) and mode == 'wrong_replicas':
        sys.exit(1)
    print('condition met')
elif command == 'logs':
    if mode != 'control_missing':
        print('Контрольное выделение 16 MiB выполнено.')
    print('Пытаемся выделить 256 MiB при лимите 64Mi.')
elif command == 'get':
    resource = arguments[1]
    query = ' '.join(arguments)
    if resource == 'deployment':
        print(state['replicas'])
    elif resource == 'pods':
        if 'job-name=memory-limit' in query:
            print('memory-limit-test')
        elif 'jsonpath' in query:
            print('resources-0')
        elif 'name' in arguments:
            for number in range(state['replicas']):
                print(f'pod/resources-{number}')
        else:
            print('Показан список Pod.')
    elif resource.startswith('pod/resources-'):
        print('50m 32Mi 200m 64Mi' if mode == 'resources_changed' else '50m 32Mi 100m 64Mi')
    elif resource == 'pod':
        if '.resources.limits.memory' in query:
            print('128Mi' if mode == 'memory_limit_changed' else '64Mi')
        elif '.state.terminated.reason' in query:
            reason = 'Error' if mode == 'wrong_reason' else 'OOMKilled'
            code = '1' if mode == 'wrong_exit_code' else '137'
            print(reason + ' ' + code)
        else:
            sys.exit(99)
    else:
        sys.exit(99)
else:
    sys.exit(99)
'''
MOCK_STRESS = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
assert sys.argv[1:] == ['--cpu', '1', '--cpu-method', 'loop', '--timeout', '15s', '--metrics-brief']
if os.environ['PMI21_STRESS_FAILURE'] == '1':
    sys.exit(1)
Path(os.environ['PMI21_CPU_STAT']).write_text(os.environ['PMI21_COUNTER_AFTER'])
'''


class CPUQuotaTest(unittest.TestCase):
    def run_cpu_check(self, version=2, quota='10000', counters=('3', '4'), stress_failure=False):
        with tempfile.TemporaryDirectory(prefix='.pmi21-cpu-', dir=PROJECT) as directory:
            directory = Path(directory)
            cgroup = directory / 'cgroup'
            cpu = cgroup if version == 2 else cgroup / 'cpu,cpuacct'
            cpu.mkdir(parents=True)
            cpu_stat = cpu / 'cpu.stat'
            before = 'nr_throttled ' + counters[0] + '\n' if counters[0] else ''
            after = 'nr_throttled ' + counters[1] + '\n' if counters[1] else ''
            cpu_stat.write_text(before)
            if version == 2:
                (cpu / 'cpu.max').write_text(quota + ' 100000\n')
            else:
                (cpu / 'cpu.cfs_quota_us').write_text(quota + '\n')
                (cpu / 'cpu.cfs_period_us').write_text('100000\n')
            stress = directory / 'stress-ng'
            stress.write_text(MOCK_STRESS)
            stress.chmod(0o755)
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                               PMI21_CPU_STAT=str(cpu_stat), PMI21_COUNTER_AFTER=after,
                               PMI21_STRESS_FAILURE='1' if stress_failure else '0')
            program = CPU_CODE.replace('/sys/fs/cgroup', str(cgroup))
            return subprocess.run(['sh', '-s'], input=program, env=environment,
                                  capture_output=True, text=True, timeout=10)

    def test_cpu_quota_and_throttling_v1_and_v2(self):
        for version in (1, 2):
            with self.subTest(version=version):
                result = self.run_cpu_check(version=version)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('до 3, после 4', result.stdout)

    def test_wrong_quota_missing_throttling_or_failed_stress_fails(self):
        cases = ((2, 'max', ('3', '4'), False),
                 (1, '-1', ('3', '4'), False),
                 (2, '50000', ('3', '4'), False),
                 (2, '10000', ('3', '3'), False),
                 (2, '10000', ('', ''), False),
                 (2, '10000', ('3', '4'), True))
        for version, quota, counters, stress_failure in cases:
            with self.subTest(version=version, quota=quota, counters=counters, stress_failure=stress_failure):
                result = self.run_cpu_check(version, quota, counters, stress_failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class ResourceScenarioTest(unittest.TestCase):
    def test_only_expected_results_are_accepted(self):
        modes = ('correct', 'resources_changed', 'cpu_failed', 'control_missing',
                 'wrong_reason', 'wrong_exit_code', 'memory_limit_changed', 'job_not_failed', 'wrong_replicas')
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='.pmi21-test-', dir=PROJECT) as directory:
                directory = Path(directory)
                executable = directory / 'kubectl'
                executable.write_text(MOCK_KUBECTL)
                executable.chmod(0o755)
                state_file = directory / 'state.json'
                state_file.write_text(json.dumps({'replicas': 2, 'memory_created': False}))
                environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                                   PMI21_STATE=str(state_file), PMI21_MODE=mode)
                result = subprocess.run(['bash', str(CHECK_SCRIPT)], env=environment,
                                        capture_output=True, text=True, timeout=20)
                expected_code = 0 if mode == 'correct' else 1
                self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
                if mode == 'correct':
                    self.assertIn(SUCCESS_MESSAGE, result.stdout)
                else:
                    self.assertNotIn(SUCCESS_MESSAGE, result.stdout)
                if mode in ('resources_changed', 'cpu_failed', 'wrong_replicas'):
                    state = json.loads(state_file.read_text())
                    self.assertFalse(state['memory_created'])


if __name__ == '__main__':
    unittest.main()
