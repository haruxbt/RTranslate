#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/dist/SafariPreview/RTranslate.app"
output="${1:-$PWD/dist/RTranslate-Safari-v0.3.7-Installer.pkg}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
# Package the verified build, without rebuilding or launching an app on this Mac.
codesign --verify --deep --strict "$app"
stage=$(mktemp -d "$PWD/work/safari-installer-XXXXXX")
mkdir -p "$stage/root"
ditto "$app" "$stage/root/RTranslate.app"
codesign --verify --deep --strict "$stage/root/RTranslate.app"
pkgbuild --analyze --root "$stage/root" "$stage/components.plist"
python3 - "$stage/components.plist" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]);rows=plistlib.loads(p.read_bytes())
for row in rows:
    row['BundleIsRelocatable']=False
    row['BundleOverwriteAction']='upgrade'
p.write_bytes(plistlib.dumps(rows))
PY
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" \
    --identifier local.webinarnihongo.installer --version "$version" \
    --install-location /Applications --ownership recommended "$output"
codesign --verify --deep --strict "$app"
echo "Created personal Safari preview installer: $output"
