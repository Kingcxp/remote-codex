"""Offline Bash client smoke checks; never install packages or access real devices."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--bash', default=shutil.which('bash'))
args, unittest_args = parser.parse_known_args()
BUNDLE = Path(__file__).resolve().parents[1]


class ClientTests(unittest.TestCase):
    def run_client(self, config, inputs='0\n', stubs=False):
        with tempfile.TemporaryDirectory(prefix='codex-client-onboarding-') as temp:
            folder = Path(temp)
            shutil.copyfile(BUNDLE / 'clients/connect.sh', folder / 'connect.sh')
            (folder / 'connection.txt').write_text(config, encoding='utf-8', newline='\n')
            environment = dict(os.environ)
            if stubs:
                bin_dir = folder / 'bin'
                bin_dir.mkdir()
                for name, body in {'tailscale': 'if [[ "$1" == status ]]; then printf \'{"BackendState":"Running"}\'; else printf "100.64.0.50\\n"; fi', 'curl': 'printf \'{"ok":true}\''}.items():
                    stub = bin_dir / name
                    stub.write_text('#!/usr/bin/env bash\n' + body + '\n', encoding='utf-8', newline='\n')
                    stub.chmod(0o700)
                # Convert on Windows for the MSYS shell PATH; do not replace the parent environment.
                bin_posix = bin_dir.as_posix()
                if os.name == 'nt':
                    bin_posix = '/' + bin_posix[0].lower() + bin_posix[2:]
                environment['CODEX_TEST_BIN'] = bin_posix
                command = [args.bash, '-c', 'export PATH="$CODEX_TEST_BIN:$PATH"; bash ./connect.sh']
            else:
                command = [args.bash, './connect.sh']
            result = subprocess.run(command, cwd=folder, env=environment, input=inputs, text=True,
                                    encoding='utf-8', capture_output=True, timeout=15)
            self.assertFalse((folder / 'PWNED').exists())
            return result

    def test_syntax(self):
        result = subprocess.run([args.bash, '-n', 'clients/connect.sh'], cwd=BUNDLE, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_valid_configuration_opens_menu_and_exits(self):
        r = self.run_client('HostName=codex-host.tailtest.ts.net\nHostIP=100.64.0.10\nSSHUser=tester\nFingerprint=\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('连接 codex-host.tailtest.ts.net', r.stdout)

    def test_crlf_configuration(self):
        r = self.run_client('HostName=codex-host.tailtest.ts.net\r\nHostIP=100.64.0.10\r\nSSHUser=tester\r\nFingerprint=\r\n')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_full_root_url_and_pasted_whitespace_are_normalized(self):
        for host in ['codex-host.tailtest.ts.net', 'https://codex-host.tailtest.ts.net/', 'codex-host.tailtest.ts.net.']:
            with self.subTest(host=host):
                r = self.run_client(f'HostName=  {host}  \nHostIP= 100.100.100.10 \nSSHUser= testuser \n')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('连接 codex-host.tailtest.ts.net', r.stdout)

    def test_error_identifies_host_instead_of_blames_valid_username(self):
        for host in ['codex-host', 'http://codex-host.tailtest.ts.net/', 'https://codex-host.tailtest.ts.net/path',
                     'https://codex-host.tailtest.ts.net/?token=keep-private', 'https://evil@example.ts.net/']:
            with self.subTest(host=host):
                r = self.run_client(f'HostName={host}\nHostIP=100.100.100.10\nSSHUser=testuser\n')
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('主机名格式不正确', r.stderr)
                self.assertNotIn('Windows 用户名格式不正确', r.stderr)

    def test_username_field_requires_local_name_and_reports_it_separately(self):
        r = self.run_client('HostName=codex-host.tailtest.ts.net\nHostIP=100.100.100.10\nSSHUser=example\\testuser\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Windows 用户名格式不正确', r.stderr)
        self.assertNotIn('主机名格式不正确', r.stderr)

    def test_manual_prompts_accept_copied_url_and_current_local_name(self):
        r = self.run_client('', inputs='https://codex-host.tailtest.ts.net/\n100.100.100.10\ntestuser\n0\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('连接 codex-host.tailtest.ts.net', r.stdout)

    def test_rejects_shell_code_duplicate_and_non_tailnet_address(self):
        base = 'HostName=codex-host.tailtest.ts.net\nHostIP=100.64.0.10\nSSHUser=tester\n'
        invalid = [base + 'execute=touch PWNED\n', base.replace('tester', '$(touch PWNED)'),
                   base + 'SSHUser=other\n', base.replace('100.64.0.10', '100.064.0.10'),
                   base.replace('100.64.0.10', '192.168.1.1'), base.replace('100.64.0.10', '100.64.0.999')]
        for config in invalid:
            with self.subTest(config=config):
                self.assertNotEqual(self.run_client(config).returncode, 0)

    def test_health_check_with_stubbed_network_tools(self):
        r = self.run_client('HostName=codex-host.tailtest.ts.net\nHostIP=100.64.0.10\nSSHUser=tester\n', inputs='2\n0\n', stubs=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('{"ok":true}', r.stdout)
        self.assertIn('HTTPS 可达', r.stdout)


if __name__ == '__main__':
    unittest.main(argv=[__file__, *unittest_args])
