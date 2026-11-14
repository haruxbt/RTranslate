import importlib.util,plistlib,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('branding',ROOT/'scripts/apply_branding.py');branding=importlib.util.module_from_spec(spec);spec.loader.exec_module(branding)
class RenameChecks(unittest.TestCase):
 def fixture(self,root,name,identifier='local.webinarnihongo.app'):
  app=root/'Applications'/name;(app/'Contents/MacOS').mkdir(parents=True);(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier}));exe=app/'Contents/MacOS/WebinarNihongo';shutil.copyfile('/bin/sleep',exe);exe.chmod(0o755);return app
 def run_post(self,root):return subprocess.run(['/bin/sh',str(ROOT/'scripts/installer/postinstall'),'fixture','/Applications',str(root)],capture_output=True,text=True)
 def test_old_bundle_is_backed_up_without_touching_data(self):
  with tempfile.TemporaryDirectory() as tmp:
   r=Path(tmp);old=self.fixture(r,'Webinar Nihongo.app');new=self.fixture(r,'RTranslate.app');(r/'private/var/backups').mkdir(parents=True)
   data=r/'Library/Application Support/RTranslate/Assets';data.mkdir(parents=True);(data/'owned-test').write_text('keep')
   self.assertEqual(self.run_post(r).returncode,0);self.assertFalse(old.exists());self.assertTrue(new.exists());self.assertEqual((data/'owned-test').read_text(),'keep');self.assertEqual(len(list((r/'private/var/backups').glob('*/WebinarNihongo.bundlebackup'))),1)
 def test_unrelated_old_app_is_not_moved(self):
  with tempfile.TemporaryDirectory() as tmp:
   r=Path(tmp);old=self.fixture(r,'Webinar Nihongo.app','example.unrelated');self.fixture(r,'RTranslate.app');self.assertEqual(self.run_post(r).returncode,0);self.assertTrue(old.exists())
 def test_missing_replacement_and_symlink_are_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   r=Path(tmp);old=self.fixture(r,'Webinar Nihongo.app');self.assertNotEqual(self.run_post(r).returncode,0);self.assertTrue(old.exists());new=self.fixture(r,'RTranslate.app');old.rename(r/'owned-original');old.symlink_to(r/'owned-original',target_is_directory=True);self.assertNotEqual(self.run_post(r).returncode,0);self.assertTrue((r/'owned-original').exists())
 def test_installer_rejects_running_installed_copy(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.fixture(Path(tmp),'RTranslate.app');p=subprocess.Popen([str(app/'Contents/MacOS/WebinarNihongo'),'30'])
   try:self.assertNotEqual(subprocess.run(['/bin/sh',str(ROOT/'scripts/installer/preinstall')],capture_output=True).returncode,0)
   finally:p.terminate();p.wait(timeout=5)
 def test_localized_bundle_names_keep_identity(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.fixture(Path(tmp),'RTranslate.app');branding.apply(app);info=plistlib.loads((app/'Contents/Info.plist').read_bytes());self.assertEqual(info['CFBundleIdentifier'],'local.webinarnihongo.app');self.assertEqual(info['CFBundleDisplayName'],'RTranslate');self.assertIn('R翻訳',(app/'Contents/Resources/ja.lproj/InfoPlist.strings').read_text());self.assertIn('RTranslate',(app/'Contents/Resources/en.lproj/InfoPlist.strings').read_text())
if __name__=='__main__':unittest.main()
