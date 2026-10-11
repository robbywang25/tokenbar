"""Offline verification regressions; never signs, mounts, submits, or reads credentials."""
from pathlib import Path
import hashlib, io, plistlib, stat, subprocess, tempfile, types, unittest, zipfile
from unittest.mock import patch
path=Path(__file__).resolve().parents[1] / 'verify-release.sh'
code=path.read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
m=types.ModuleType('verification_under_test'); exec(compile(code,str(path),'exec'),m.__dict__)

class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='tokenbar-verifier-tests-'); self.root=Path(self.temp.name)
        self.zip=self.root/'TokenBar-0.2.1-universal-widget.zip'; self.dmg=self.root/'TokenBar-0.2.1-universal-widget.dmg'; self.check=self.root/'SHA256SUMS.txt'
        self.zip.write_bytes(b'synthetic zip'); self.dmg.write_bytes(b'synthetic dmg')
        self.lines=[m.sha256(p)+'  '+p.name for p in (self.zip,self.dmg)]
        self.check.write_text('\n'.join(self.lines)+'\n')
    def tearDown(self): self.temp.cleanup()
    def zip_entries(self, extra=(), duplicate=False):
        with zipfile.ZipFile(self.zip,'w') as z:
            z.writestr('TokenBar.app/Contents/Info.plist',b'synthetic plist')
            z.writestr('__MACOSX/TokenBar.app/Contents/._Info.plist',b'synthetic resource')
            for name,kind in extra:
                info=zipfile.ZipInfo(name); info.create_system=3; info.external_attr=(kind|0o644)<<16
                z.writestr(info,b'synthetic')
    def test_exact_checksums_pass(self): m.verify_checksums(self.check,self.zip,self.dmg)
    def test_changed_bytes_fail(self):
        self.dmg.write_bytes(b'changed after stapling')
        with self.assertRaisesRegex(m.VerificationError,'mismatch'): m.verify_checksums(self.check,self.zip,self.dmg)
    def test_checksum_duplicate_path_and_extra_rejected(self):
        for rows in [[self.lines[0],self.lines[0]], [self.lines[0].replace('TokenBar-','../TokenBar-'),self.lines[1]], self.lines+[self.lines[1]], self.lines[:1]]:
            self.check.write_text('\n'.join(rows)+'\n')
            with self.assertRaises(m.VerificationError): m.verify_checksums(self.check,self.zip,self.dmg)
    def test_zip_accepts_only_expected_app_and_appledouble(self):
        self.zip_entries(); m.validate_zip(self.zip)
    def test_zip_traversal_absolute_windows_and_extra_root_rejected(self):
        for name in ['../escape','/outside','TokenBar.app/../escape','TokenBar.app/./escape','TokenBar.app//escape','TokenBar.app\\..\\escape','unrelated.txt']:
            self.zip_entries([(name,stat.S_IFREG)])
            with self.assertRaises(m.VerificationError): m.validate_zip(self.zip)
    def test_zip_links_devices_collisions_and_limits_rejected(self):
        for entries in [[('TokenBar.app/Contents/link',stat.S_IFLNK)], [('TokenBar.app/Contents/device',stat.S_IFCHR)], [('tokenbar.app/contents/info.plist',stat.S_IFREG)], [('TokenBar.app/Contents/not-a-directory',stat.S_IFDIR)]]:
            self.zip_entries(entries)
            with self.assertRaises(m.VerificationError): m.validate_zip(self.zip)
        self.zip_entries()
        with patch.object(m,'MAX_ZIP_BYTES',1):
            with self.assertRaises(m.VerificationError): m.validate_zip(self.zip)
    def test_tree_manifest_rejects_symlinks(self):
        app=self.root/'app'; app.mkdir(); (app/'linked').symlink_to(self.dmg)
        with self.assertRaisesRegex(m.VerificationError,'symlink'): m.tree_manifest(app)
    def test_signature_metadata_requires_developer_id_team_timestamp_runtime(self):
        good='Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Oct 11, 2026\nCodeDirectory flags=0x10000(runtime)\n'
        for text in [good.replace('Developer ID Application','Apple Development'),good.replace('ABCDEFGHIJ','ZZZZZZZZZZ'),good.replace('Timestamp=Oct 11, 2026\n',''),good.replace('flags=0x10000(runtime)','flags=0x0(none)')]:
            with patch.object(m,'run',return_value=types.SimpleNamespace(stderr=text.encode())):
                with self.assertRaises(m.VerificationError): m.signing_details(Path('Fixture.app'),'ABCDEFGHIJ','arm64',True)
        with patch.object(m,'run',return_value=types.SimpleNamespace(stderr=good.encode())): m.signing_details(Path('Fixture.app'),'ABCDEFGHIJ','arm64',True)
    def test_codesign_gate_uses_apple_developer_id_requirement(self):
        with patch.object(m,'run',return_value=types.SimpleNamespace(stdout=b'')) as run:
            m.verify_signature(Path('Fixture.app'))
        argv=run.call_args.args[0]
        self.assertIn('--all-architectures',argv); self.assertIn('--test-requirement',argv)
        self.assertEqual(argv[-2], '=' + m.DEVELOPER_ID_REQUIREMENT)
        self.assertTrue(argv[-2].startswith('=anchor apple generic'))
        self.assertIn('1.2.840.113635.100.6.1.13',argv[-2])
    def test_pre_notary_ready_does_not_claim_notarized(self):
        response=types.SimpleNamespace(returncode=0,stdout=b'',stderr=b'')
        with patch.object(m.shutil,'which',return_value='/usr/bin/syspolicy_check'), patch.object(m.subprocess,'run',return_value=response) as run:
            self.assertEqual(m.pre_notary_policy(Path('Fixture.app')),'notary-submission-ready')
        self.assertEqual(run.call_count,1)
        self.assertEqual(run.call_args.args[0][:2],['syspolicy_check','notary-submission'])
    def test_pre_notary_pending_requires_independent_exact_spctl_evidence(self):
        responses=[types.SimpleNamespace(returncode=70,stdout=b'',stderr=b'Codesign Error'),
                   types.SimpleNamespace(returncode=3,stdout=b'',stderr=b'Fixture.app: rejected\nsource=Unnotarized Developer ID\n')]
        with patch.object(m.shutil,'which',return_value='/usr/bin/syspolicy_check'), patch.object(m.subprocess,'run',side_effect=responses) as run:
            self.assertEqual(m.pre_notary_policy(Path('Fixture.app')),'notarization-pending')
        self.assertEqual(run.call_args_list[1].args[0],['spctl','--assess','--type','execute','--verbose=4','Fixture.app'])
    def test_pre_notary_other_policy_errors_remain_fail_closed(self):
        for code,reason in [(3,b'source=no usable signature'),(0,b'source=Unnotarized Developer ID'),
                            (70,b'source=Unnotarized Developer ID'),(3,b'source=Unnotarized Developer ID plus unknown failure')]:
            responses=[types.SimpleNamespace(returncode=70,stdout=b'',stderr=b'Codesign Error'),
                       types.SimpleNamespace(returncode=code,stdout=b'',stderr=reason)]
            with patch.object(m.shutil,'which',return_value='/usr/bin/syspolicy_check'), patch.object(m.subprocess,'run',side_effect=responses):
                with self.assertRaisesRegex(m.VerificationError,'other than a pending'): m.pre_notary_policy(Path('Fixture.app'))
        with patch.object(m.shutil,'which',return_value=None):
            with self.assertRaisesRegex(m.VerificationError,'required'): m.pre_notary_policy(Path('Fixture.app'))
    def test_final_distribution_never_uses_pending_notarization_exception(self):
        args=types.SimpleNamespace(app=str(self.root/'TokenBar.app'),zip=str(self.zip),dmg=str(self.dmg),checksums=str(self.check),team_id='ABCDEFGHIJ')
        def policy_failure(argv,label,**kwargs):
            if argv[:2]==['syspolicy_check','distribution']: raise m.VerificationError('distribution policy failed')
            return types.SimpleNamespace(stdout=b'',stderr=b'')
        with patch.object(m,'verify_checksums'),patch.object(m,'validate_zip'),patch.object(m,'signing_details'), \
             patch.object(m,'verify_signature'),patch.object(m,'verify_ticket'),patch.object(m.shutil,'which',return_value='/usr/bin/syspolicy_check'), \
             patch.object(m,'run',side_effect=policy_failure),patch.object(m,'pre_notary_policy') as pending:
            with self.assertRaisesRegex(m.VerificationError,'distribution policy failed'):
                m.verify_artifacts(args,{'version':'0.2.1'})
            pending.assert_not_called()
    def test_mock_app_rejects_extra_entitlements_bad_version_architecture_and_target(self):
        app=self.root/'TokenBar.app'; widget=app/'Contents/PlugIns/TokenBarWidget.appex'; (widget/'Contents').mkdir(parents=True)
        group='ABCDEFGHIJ.wang.robby.tokenbar'
        info={'CFBundleIdentifier':m.APP_ID,'CFBundleExecutable':'TokenBar','LSUIElement':True,'CFBundleShortVersionString':'0.2.1','CFBundleVersion':'10','LSMinimumSystemVersion':'14.0','TokenBarAppGroup':group}
        w=dict(info,CFBundleIdentifier=m.WIDGET_ID,CFBundleExecutable='TokenBarWidget',NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info)); (widget/'Contents/Info.plist').write_bytes(plistlib.dumps(w))
        rights={'com.apple.security.application-groups':[group]}
        def ent(bundle,arch): return dict(rights,**({'com.apple.security.app-sandbox':True} if bundle==widget else {}))
        def fake_run(argv,label,**kw):
            if argv[0]=='lipo': return types.SimpleNamespace(stdout=b'arm64 x86_64')
            if 'vtool' in argv: return types.SimpleNamespace(stdout=b'platform MACOS\nminos 14.0\nsdk 26.5')
            if 'nm' in argv: return types.SimpleNamespace(stdout=b'_NSExtensionMain')
            raise AssertionError(argv)
        with patch.object(m,'run',side_effect=fake_run),patch.object(m,'signing_details'),patch.object(m,'verify_signature'),patch.object(m,'entitlements',side_effect=ent):
            self.assertEqual(m.verify_app(app,'ABCDEFGHIJ')['version'],'0.2.1')
            rights['com.apple.security.get-task-allow']=True
            with self.assertRaisesRegex(m.VerificationError,'entitlements'): m.verify_app(app,'ABCDEFGHIJ')
            del rights['com.apple.security.get-task-allow']
            w['CFBundleVersion']='9'; (widget/'Contents/Info.plist').write_bytes(plistlib.dumps(w))
            with self.assertRaisesRegex(m.VerificationError,'versions'): m.verify_app(app,'ABCDEFGHIJ')
            w['CFBundleVersion']='10'; (widget/'Contents/Info.plist').write_bytes(plistlib.dumps(w))
            with patch.object(m,'run',return_value=types.SimpleNamespace(stdout=b'arm64')):
                with self.assertRaisesRegex(m.VerificationError,'both arm64'): m.verify_app(app,'ABCDEFGHIJ')
            def high_target(argv,label,**kw):
                if 'vtool' in argv: return types.SimpleNamespace(stdout=b'platform MACOS\nminos 15.0\nsdk 26.5')
                return fake_run(argv,label,**kw)
            with patch.object(m,'run',side_effect=high_target):
                with self.assertRaisesRegex(m.VerificationError,'exceeds macOS 14'): m.verify_app(app,'ABCDEFGHIJ')

if __name__ == '__main__':
    unittest.main(verbosity=2)
