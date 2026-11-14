import contextlib,hashlib,importlib.util,io,json,tarfile,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('asset_worker',Path(__file__).resolve().parents[2]/'scripts/asset_worker.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Assets(unittest.TestCase):
 def test_prepare_reuse_and_repair(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);source=root/'import';support=root/'support';dest=root/'assets';source.mkdir();support.mkdir();(source/'weights').write_bytes(b'owned test weights');(support/'config').write_bytes(b'owned configuration')
   with tarfile.open(source/'open-jtalk-1.11.tar.gz','w:gz') as tar:
    data=b'dictionary';entry=tarfile.TarInfo('open_jtalk_dic_utf_8-1.11/sys.dic');entry.size=len(data);tar.addfile(entry,io.BytesIO(data))
   files=[{'path':n,'sha256':m.digest((support if n=='config' else source)/n),**({'support':True} if n=='config' else {'url':'https://example.invalid/'+n})} for n in ['weights','config','open-jtalk-1.11.tar.gz']]
   catalog={'version':1,'files':files,'dictionary':{'open_jtalk_dic_utf_8-1.11/sys.dic':hashlib.sha256(b'dictionary').hexdigest()}}
   with contextlib.redirect_stdout(io.StringIO()),patch.object(m.urllib.request,'urlopen',side_effect=AssertionError('no network')):
    m.prepare(catalog,dest,support,source);self.assertTrue((dest/'ready.json').exists());m.prepare(catalog,dest,support)
    (dest/'config').write_bytes(b'corrupt');(dest/'voicevox/dict/open_jtalk_dic_utf_8-1.11/sys.dic').write_bytes(b'corrupt');m.prepare(catalog,dest,support)
   self.assertEqual((dest/'config').read_bytes(),b'owned configuration');self.assertEqual((dest/'voicevox/dict/open_jtalk_dic_utf_8-1.11/sys.dic').read_bytes(),b'dictionary')
 def test_paths_and_links_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   with self.assertRaises(ValueError):m.child(Path(tmp),'../escape')
   with self.assertRaises(ValueError):m.child(Path(tmp),'/etc/passwd')
 def test_resumes_only_valid_partial_response(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);(root/'weights.partial').write_bytes(b'hello ')
   class Response(io.BytesIO):
    status=206;url='https://example.invalid/weights';headers={'Content-Range':'bytes 6-10/11'}
   catalog={'version':1,'files':[{'path':'weights','url':'https://example.invalid/weights','sha256':hashlib.sha256(b'hello world').hexdigest()}],'dictionary':{}}
   # Stop before dictionary extraction; completed weights are already verified.
   with patch.object(m.urllib.request,'urlopen',return_value=Response(b'world')) as fetch,contextlib.redirect_stdout(io.StringIO()):
    with self.assertRaises(FileNotFoundError):m.prepare(catalog,root,root)
   self.assertEqual(fetch.call_args.args[0].get_header('Range'),'bytes=6-');self.assertEqual((root/'weights').read_bytes(),b'hello world');self.assertFalse((root/'ready.json').exists())
if __name__=='__main__':unittest.main()
