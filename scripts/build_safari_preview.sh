#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p work dist/SafariPreview
python3 - <<'PY'
import subprocess,os
running=subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()
if os.environ.get('RTRANSLATE_STAGE_ONLY')!='1' and any('/dist/SafariPreview/' in p and '/Contents/MacOS/WebinarNihongo' in p or p.strip().endswith('/Safari.app/Contents/MacOS/Safari') for p in running):
    raise SystemExit('Close Safari and the preview translator before building. No installed app files were changed.')
PY
swift build -c release --product WebinarNihongo
binary_dir=$(swift build -c release --show-bin-path)
destination="$PWD/dist/SafariPreview/RTranslate.app"
stage=$(mktemp -d "${TMPDIR:-/tmp}/rtranslate-safari-app-XXXXXX")
app="$stage/RTranslate.app"
# Build a separate complete bundle; never copy into Safari's loaded resources.
base="${RTRANSLATE_BASE_APP:-$destination}"
if [[ ! -d "$base" ]]; then base="$PWD/dist/SafariPreview/Webinar Nihongo.app"; fi
if [[ ! -d "$base" ]]; then base="$PWD/dist/Webinar Nihongo.app"; fi
ditto "$base" "$app"
cp "$binary_dir/WebinarNihongo" "$app/Contents/MacOS/WebinarNihongo"
cp SafariExtension/Design/RTranslate.icns "$app/Contents/Resources/"
cp SafariExtension/Resources/toolbar-32.png "$app/Contents/Resources/MenuBarTemplate.png"
cp scripts/plamo_worker.py scripts/voicevox_worker.py scripts/asset_worker.py "$app/Contents/Resources/"
cp Resources/rspeech-common-ja.json "$app/Contents/Resources/"
ditto Resources/AssetCatalog "$app/Contents/Resources/AssetCatalog"
ditto Resources/AssetSupport "$app/Contents/Resources/AssetSupport"
# Model data lives in Application Support, never in the distributable app.
python3 - "$app" <<'PY'
from pathlib import Path
import shutil,sys
resources = Path(sys.argv[1]) / 'Contents/Resources'
python = resources / 'Python'
packages = python / 'lib/python3.13/site-packages'
# Keep licenses and package metadata. The pinned workers only use the AutoTokenizer path.
unused = [resources / 'Models', resources / 'VoiceRuntime/lib', python / 'include']
unused += [packages / name for name in ('pip', 'hf_xet', 'pygments')]
unused += [path for path in (packages / 'transformers/models').iterdir()
           if path.is_dir() and path.name not in {'auto', 'encoder_decoder'}]
for path in unused:
    if path.is_dir():
        shutil.rmtree(path)
PY
appex="$app/Contents/PlugIns/Webinar Safari.appex"
mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
ditto SafariExtension/Resources "$appex/Contents/Resources"
extension_executable=WebinarSafariExtension
if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    "$DEVELOPER_DIR/usr/bin/xcodebuild" \
        -project 'SafariExtension/Xcode/Webinar Safari/Webinar Safari.xcodeproj' \
        -target 'Webinar Safari Extension' -configuration Release \
        CODE_SIGNING_ALLOWED=NO ARCHS=arm64 SYMROOT="$PWD/work/safari-xcode-build" \
        OBJROOT="$PWD/work/safari-xcode-intermediates" \
        CONFIGURATION_BUILD_DIR="$PWD/work/safari-xcode-products" build
    ditto 'work/safari-xcode-products/Webinar Safari Extension.appex' "$appex"
    extension_executable='Webinar Safari Extension'
else
swiftc -parse-as-library -application-extension -target arm64-apple-macos26.0 \
    -module-name WebinarSafariExtension SafariExtension/Native/SafariWebExtensionHandler.swift \
    -framework SafariServices -framework AppKit -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$appex/Contents/MacOS/WebinarSafariExtension"
fi
python3 - "$app" "$appex" "$extension_executable" <<'PY'
from pathlib import Path
import plistlib,sys
app,ext=map(Path,sys.argv[1:3]);p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
info['CFBundleShortVersionString']='0.4.1';info['CFBundleVersion']='24';info['LSUIElement']=True;info['CFBundleDisplayName']='R翻訳';info['CFBundleName']='RTranslate';info['CFBundleIconFile']='RTranslate.icns';p.write_bytes(plistlib.dumps(info))
info={'CFBundleIdentifier':'local.webinarnihongo.app.safari','CFBundleName':'R翻訳',
      'CFBundleExecutable':'WebinarSafariExtension','CFBundlePackageType':'XPC!',
      'CFBundleShortVersionString':'0.4.1','CFBundleVersion':'24','LSMinimumSystemVersion':'26.0',
      'CFBundleSupportedPlatforms':['MacOSX'],
      'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},
      'NSExtension':{'NSExtensionPointIdentifier':'com.apple.Safari.web-extension',
                    'NSExtensionPrincipalClass':'SafariWebExtensionHandler'}}
info['CFBundleExecutable']=sys.argv[3]
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
for name in ('WebinarSafariExtension', 'Webinar Safari Extension'):
    if name != sys.argv[3]:
        (ext/'Contents/MacOS'/name).unlink(missing_ok=True)
Path('work/safari-preview-entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
PY
python3 scripts/apply_branding.py "$app"
# Sign generated bundles outside iCloud and remove only Finder/resource-fork metadata.
for bundle in "$appex" "$app"; do
    for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
        xattr -dr "$attribute" "$bundle" 2>/dev/null || true
        xattr -d "$attribute" "$bundle" 2>/dev/null || true
    done
done
codesign --force --sign - --entitlements work/safari-preview-entitlements.plist "$appex"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ "${RTRANSLATE_STAGE_ONLY:-0}" == "1" ]]; then
    python3 - "$app" <<'PY_STAGE'
import json,sys
from pathlib import Path
Path('work/safari-preview-staged.json').write_text(json.dumps({'app':sys.argv[1],'version':'0.4.1'},indent=2))
PY_STAGE
    echo "Built and verified separate staged app: $app"
    exit 0
fi
python3 - "$app" "$destination" <<'PY'
from pathlib import Path
import hashlib,json,os,subprocess,sys
app,destination=map(Path,sys.argv[1:])
processes=subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()
if any(line.strip().startswith(str(destination)+'/') or line.strip().endswith('/Safari.app/Contents/MacOS/Safari') for line in processes):
    raise SystemExit('Finished staged build; close Safari and Webinar Nihongo before replacing the preview app. Staged app: '+str(app))
backup=app.parent/'previous-app.bundlebackup'
if destination.exists():os.rename(destination,backup)
try:os.rename(app,destination)
except BaseException:
    if backup.exists():os.rename(backup,destination)
    raise
legacy=destination.with_name('Webinar Nihongo.app')
if legacy.exists():os.rename(legacy,app.parent/'legacy-app.bundlebackup')
resources=destination/'Contents/PlugIns/Webinar Safari.appex/Contents/Resources'
files={str(f.relative_to(resources)):hashlib.sha256(f.read_bytes()).hexdigest() for f in resources.iterdir() if f.is_file()}
Path('work/safari-preview-build-manifest.json').write_text(json.dumps({'version':'0.4.1','build':'24','resources':files,'backup':str(backup)},indent=2))
PY
codesign --verify --deep --strict "$destination"
echo "Built and verified Safari preview: $destination"
