#!/usr/bin/env python3
"""Exercise real packaging scripts in disposable fixtures; never use a real signing key."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "A" * 40
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def has(x): return x in args
with open(os.environ['CALLS'], 'a') as f: f.write(name + ' ' + ' '.join(args) + '\n')
fail = os.environ.get('FAIL', '')
if name == 'swift':
    if fail == 'compile': sys.exit(1)
    path = pathlib.Path.cwd() / '.build/release'
    path.mkdir(parents=True, exist_ok=True)
    (path/'SpacesDock').write_text('new binary')
    (path/'SpacesDock').chmod(0o755)
    if has('--show-bin-path'): print(path)
elif name == 'security':
    kind = os.environ.get('CERT_KIND', 'Developer ID Application')
    print('  1) ' + 'A'*40 + ' "' + kind + ': Fixture (TESTTEAM01)"')
elif name == 'codesign':
    if has('--sign') and fail == 'sign': sys.exit(1)
    if has('--verify') and fail == 'verify': sys.exit(1)
    if has('-dv') or has('--display'):
        print('Identifier=fr.local.spacesdock\nTeamIdentifier=TESTTEAM01\nAuthority=Developer ID Application: Fixture\nCodeDirectory v=20500 size=100 ' + ('flags=0x0(none)' if fail == 'runtime-missing' else 'flags=0x10000(runtime)') + '\nTimestamp=Oct 29, 2026', file=sys.stderr)
    if has('-r-'): print('designated => identifier "fr.local.spacesdock" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01"', file=sys.stderr)
elif name == 'mv':
    # Fail precisely during stage promotion, but allow the previous bundle rollback.
    if fail == 'promote' and args[0].endswith('/Spaces Dock.app') and '.spaces-dock-build.' in args[0]: sys.exit(1)
    shutil.move(args[0], args[1])
elif name == 'xcrun':
    if args[0] == '--find': print('/fixture/' + args[1])
    elif args[:2] == ['notarytool', 'submit']:
        if fail == 'notary': sys.exit(1)
        print(json.dumps({'status': 'Invalid' if fail == 'notary-invalid' else 'Accepted', 'id':'00000000-0000-0000-0000-000000000001'}))
    elif args[:2] == ['notarytool', 'log']:
        pathlib.Path(args[3]).write_text('{"status":"Accepted","issues":null}')
    elif args[:2] == ['stapler', 'staple'] and fail == 'staple': sys.exit(1)
    elif args[:2] == ['stapler', 'validate'] and fail == 'staple-validate': sys.exit(1)
elif name == 'spctl':
    if fail == 'gatekeeper': sys.exit(1)
    print('accepted\nsource=Notarized Developer ID', file=sys.stderr)
else:
    raise SystemExit('Unknown stub: ' + name)
'''

class PackagingChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='spacesdock-packaging-')
        self.base = Path(self.tmp.name)
        self.project = self.base/'project'
        self.project.mkdir()
        for name in ['build.sh', 'release.sh', 'Info.plist']:
            if (ROOT/name).exists(): shutil.copy(ROOT/name, self.project/name)
        for name in ['scripts', 'Resources']:
            if (ROOT/name).exists(): shutil.copytree(ROOT/name, self.project/name)
        self.out = self.base/'output with spaces'
        self.old = self.out/'Spaces Dock.app'
        (self.old/'Contents/MacOS').mkdir(parents=True)
        (self.old/'Contents/MacOS/SpacesDock').write_text('working binary')
        (self.old/'keep').write_text('previous bundle')
        self.bin = self.base/'bin'
        self.bin.mkdir()
        for name in ['swift','security','codesign','mv','xcrun','spctl']:
            stub = self.bin/name
            stub.write_text(STUB)
            stub.chmod(0o755)
        self.calls = self.base/'calls'
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], CALLS=str(self.calls), SPACES_DOCK_SIGNING_IDENTITY=IDENTITY)
        for name in ['FAIL','SPACES_DOCK_BUILD_MODE','SPACES_DOCK_NOTARY_PROFILE','SPACES_DOCK_DEVELOPER_ID']:
            self.env.pop(name, None)
    def tearDown(self): self.tmp.cleanup()
    def run_script(self, name, **env):
        return subprocess.run(['bash', str(self.project/name), str(self.out)], env=dict(self.env, **env), capture_output=True, text=True)
    def assert_old_intact(self):
        self.assertEqual((self.old/'Contents/MacOS/SpacesDock').read_text(), 'working binary')
        self.assertTrue((self.old/'keep').exists())
    def test_sign_failure_preserves_previous_bundle(self):
        result = self.run_script('build.sh', FAIL='sign')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()
    def test_verification_failure_preserves_previous_bundle(self):
        self.assertNotEqual(self.run_script('build.sh', FAIL='verify').returncode, 0)
        self.assert_old_intact()
    def test_compile_failure_preserves_previous_bundle(self):
        self.assertNotEqual(self.run_script('build.sh', FAIL='compile').returncode, 0)
        self.assert_old_intact()
    def test_missing_runtime_is_rejected_even_when_codesign_verify_succeeds(self):
        result = self.run_script('build.sh', FAIL='runtime-missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Hardened runtime absent', result.stderr)
        self.assert_old_intact()
    def test_promote_failure_restores_previous_bundle(self):
        self.assertNotEqual(self.run_script('build.sh', FAIL='promote').returncode, 0)
        self.assert_old_intact()
    def test_success_replaces_whole_bundle_after_verification(self):
        result = self.run_script('build.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.old/'Contents/MacOS/SpacesDock').read_text(), 'new binary')
        self.assertFalse((self.old/'keep').exists())
        self.assertTrue((self.old/'Contents/Resources/PrivacyInfo.xcprivacy').is_file())
        self.assertTrue((self.old/'Contents/Resources/AppIcon.icns').is_file())
        self.assertIn('--options runtime', self.calls.read_text())
    def test_missing_and_ad_hoc_identity_are_rejected(self):
        for identity in ['', '-']:
            with self.subTest(identity=identity):
                self.assertNotEqual(self.run_script('build.sh', SPACES_DOCK_SIGNING_IDENTITY=identity).returncode, 0)
                self.assert_old_intact()
    def test_concurrent_build_lock_preserves_previous_bundle(self):
        (self.out/'.spaces-dock-build.lock').mkdir()
        self.assertNotEqual(self.run_script('build.sh').returncode, 0)
        self.assert_old_intact()
    def test_public_release_rejects_development_certificate_before_build(self):
        result = self.run_script('release.sh', SPACES_DOCK_DEVELOPER_ID=IDENTITY, SPACES_DOCK_NOTARY_PROFILE='fixture', CERT_KIND='Apple Development')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('swift ', self.calls.read_text() if self.calls.exists() else '')
        self.assertIn('Developer ID Application', result.stderr)
    def test_public_release_requires_explicit_credentials(self):
        result = self.run_script('release.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(self.out.glob('Spaces-Dock-*')))
    def test_failed_public_gates_never_publish_archive(self):
        gates = {'notary':'notarytool submit', 'notary-invalid':'notarytool log', 'staple':'stapler staple', 'staple-validate':'stapler validate', 'gatekeeper':'spctl --assess'}
        for failure, expected_call in gates.items():
            with self.subTest(failure=failure):
                result = self.run_script('release.sh', SPACES_DOCK_DEVELOPER_ID=IDENTITY, SPACES_DOCK_NOTARY_PROFILE='fixture', FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_call, self.calls.read_text(), result.stderr)
                self.assertFalse(any(self.out.glob('Spaces-Dock-*')), result.stderr)
                self.assert_old_intact()
    def test_public_release_success_verifies_archive_roundtrip(self):
        result = self.run_script('release.sh', SPACES_DOCK_DEVELOPER_ID=IDENTITY, SPACES_DOCK_NOTARY_PROFILE='fixture')
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list(self.out.glob('Spaces-Dock-*/*.zip'))
        self.assertEqual(len(archives), 1)
        self.assertTrue((archives[0].parent/'SHA256SUMS').is_file())
        self.assertGreaterEqual(self.calls.read_text().count('stapler validate'), 2)
        self.assertGreaterEqual(self.calls.read_text().count('spctl --assess'), 2)
        self.assert_old_intact()

if __name__ == '__main__': unittest.main(verbosity=2)
