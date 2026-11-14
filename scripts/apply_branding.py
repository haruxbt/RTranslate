#!/usr/bin/env python3
"""Set localized bundle display names; internal IDs remain stable for upgrades."""
from pathlib import Path
import plistlib,sys

def apply(app):
    app=Path(app)
    for bundle in [app,*list((app/'Contents/PlugIns').glob('*.appex'))]:
        p=bundle/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
        info.update(CFBundleName='RTranslate',CFBundleDisplayName='RTranslate',CFBundleDevelopmentRegion='en',CFBundleLocalizations=['en','ja'])
        p.write_bytes(plistlib.dumps(info))
        for language,name in [('en','RTranslate'),('ja','R翻訳')]:
            folder=bundle/'Contents/Resources'/f'{language}.lproj';folder.mkdir(parents=True,exist_ok=True)
            (folder/'InfoPlist.strings').write_text(f'"CFBundleName" = "{name}";\n"CFBundleDisplayName" = "{name}";\n')
if __name__=='__main__':apply(sys.argv[1])
