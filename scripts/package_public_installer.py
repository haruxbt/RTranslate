#!/usr/bin/env python3
"""Prepare a clean, built installer. No developer models, history or private notes."""
import argparse,hashlib,json,plistlib,shutil,subprocess,tempfile
from apply_branding import apply
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--app',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
root=Path(__file__).resolve().parent.parent
(root/'work').mkdir(exist_ok=True)
stage=Path(tempfile.mkdtemp(prefix='public-installer-',dir=root/'work'));payload=stage/'payload';payload.mkdir();app=payload/'RTranslate.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
subprocess.run(['ditto',str(a.app),str(app)],check=True)
r=app/'Contents/Resources'
# These are historical personal development/installation notes, not product docs.
for name in ['AIR_INSTALL.md','V01_RELEASE.md']:(r/name).unlink(missing_ok=True)
for f in r.rglob('direct_url.json'):f.unlink() # installation provenance, not executable data
for folder in list(r.rglob('__pycache__')):
 if folder.is_dir():shutil.rmtree(folder)
for f in r.rglob('*.pyc'):f.unlink()
for name in ['LICENSE','THIRD_PARTY_NOTICES.md']:shutil.copy2(root/name,r/name)
(r/'INSTALL.md').write_text('''# R翻訳 / RTranslate\n\nソースからのビルドやXcodeの導入は不要です。インストール後アプリを開き、初回のモデル取得完了を待ってください。macOS 26以降・Apple Siliconが必要です。Safari拡張を使う場合はSafari設定で有効にします。試験版は未公証・仮署名のため、通常の署名済みアプリとは起動条件が異なります。\n\nモデルはアプリ外のApplication Support/RTranslate/Assetsに保存します。翻訳履歴はこのMac内で3か月保持します。自動インストールによる更新は未実装で、通知後にインストーラで更新します。Air M2 8GBの性能は未実測です。\n\nBuilt with PLaMo. VOICEVOXの選択話者のクレジットは設定で表示します。各モデル・ランタイムの利用条件はPLaMo-LICENSE、VOICEVOX-LICENSE、Python内のlicensesおよびTHIRD_PARTY_NOTICES.mdをご確認ください。\n''')
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());info['RTranslateUpdateURL']='https://api.github.com/repos/haruketh/RTranslate/releases/latest';(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
for f in r.rglob('*'):
 if not f.is_file():continue
 assert f.name not in ['history.json','hosts.yml'] and not f.name.startswith('.env'),str(f)
 assert f.suffix.lower() not in ['.key','.p12','.wav','.mp3','.mp4','.safetensors','.vvm'],str(f)
 if f.suffix.lower() in ['.pem','.txt','.json','.py','.md','.html']:
  data=f.read_bytes();assert b'-----BEGIN PRIVATE KEY-----' not in data and b'-----BEGIN RSA PRIVATE KEY-----' not in data,str(f)
assert not (r/'Models').exists()
apply(app)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
subprocess.run(['pkgbuild','--analyze','--root',str(payload),str(stage/'components.plist')],check=True,stdout=subprocess.DEVNULL)
components=plistlib.loads((stage/'components.plist').read_bytes())
for c in components:c['BundleIsRelocatable']=False;c['BundleOverwriteAction']='upgrade'
(stage/'components.plist').write_bytes(plistlib.dumps(components))
subprocess.run(['pkgbuild','--root',str(payload),'--component-plist',str(stage/'components.plist'),'--scripts',str(root/'scripts/installer'),'--identifier','local.webinarnihongo.installer','--version',info['CFBundleShortVersionString'],'--install-location','/Applications','--ownership','recommended',str(stage/'component.pkg')],check=True,stdout=subprocess.DEVNULL)
license_dir=stage/'installer-resources';license_dir.mkdir()
text='RTranslate / R翻訳\nBuilt with PLaMo\n\n独自コードはMIT。以下の第三者モデル・実行環境には各条件が適用されます。モデルの利用目的に応じてPLaMoの商用利用条件等を確認してください。VOICEVOXの音声利用時は選択話者の規約とクレジット条件に従ってください。\n\n'
for title,path in [('RTranslate MIT',root/'LICENSE'),('Third-party notices',root/'THIRD_PARTY_NOTICES.md'),('PLaMo',r/'PLaMo-LICENSE/ja'),('VOICEVOX model terms',r/'VOICEVOX-LICENSE/VOICE-MODELS-README.txt'),('VOICEVOX ONNX Runtime',r/'VOICEVOX-LICENSE/ONNX-RUNTIME-TERMS.txt')]:text+='\n\n=== '+title+' ===\n'+path.read_text()
(license_dir/'License.txt').write_text(text)
(stage/'distribution.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2"><title>RTranslate</title><license file="License.txt"/><options customize="never" hostArchitectures="arm64"/><allowed-os-versions><os-version min="26.0"/></allowed-os-versions><choices-outline><line choice="main"/></choices-outline><choice id="main" visible="false"><pkg-ref id="local.webinarnihongo.installer"/></choice><pkg-ref id="local.webinarnihongo.installer" version="'''+info['CFBundleShortVersionString']+'''">component.pkg</pkg-ref></installer-gui-script>''')
a.output.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['productbuild','--distribution',str(stage/'distribution.xml'),'--resources',str(license_dir),'--package-path',str(stage),str(a.output)],check=True)
report={'version':info['CFBundleShortVersionString'],'app':str(app),'pkg':str(a.output),'modelsBundled':False,'historyBundled':False,'updateURL':info['RTranslateUpdateURL'],'signature':'ad hoc; not notarized','installerLicenseScreen':True,'sha256':hashlib.file_digest(a.output.open('rb'),'sha256').hexdigest()}
(root/'work/public-installer-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False))
