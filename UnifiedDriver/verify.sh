#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export TMPDIR="$PWD/build/unified/scratch"
APP=build/unified/BostoTablet.app
OUT=build/unified/verified-package
rm -rf "$OUT"
pkgutil --expand-full build/unified/BostoTablet.pkg "$OUT"
codesign --verify --deep --strict "$APP"
codesign --verify --deep --strict "$OUT/Payload/BostoTablet.app"
[ "$(lipo -archs "$APP/Contents/MacOS/BostoTablet")" = arm64 ]
"$APP/Contents/MacOS/BostoTablet" --self-check
"$OUT/Payload/BostoTablet.app/Contents/MacOS/BostoTablet" --self-check
python3 - <<'PY'
from pathlib import Path
import plistlib, hashlib, xml.etree.ElementTree as ET
root=Path('build/unified')
a=root/'BostoTablet.app'
b=root/'verified-package/Payload/BostoTablet.app'
info=plistlib.loads((a/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='local.BostoTablet'
assert info['CFBundleShortVersionString']=='0.1.3'
assert info['CFBundleVersion']=='5'
assert info['CFBundleExecutable']=='BostoTablet'
assert not info.get('LSBackgroundOnly',False)
pkg=ET.parse(root/'verified-package/PackageInfo').getroot()
assert pkg.attrib['version']=='0.1.3'
assert pkg.attrib['install-location']=='/Applications'
assert pkg.attrib['relocatable']=='false'
assert pkg.attrib['postinstall-action']=='none'
assert pkg.find('scripts') is None
assert pkg.find('bundle').attrib['path']=='./BostoTablet.app'
assert set(p.name for p in (root/'verified-package/Payload').iterdir())=={'BostoTablet.app'}
files=lambda p: sorted(str(f.relative_to(p)) for f in p.rglob('*') if f.is_file())
assert files(a)==files(b)
assert set(files(a))=={'Contents/Info.plist','Contents/MacOS/BostoTablet','Contents/_CodeSignature/CodeResources'}
for name in files(a): assert (a/name).read_bytes()==(b/name).read_bytes(),name
assert not (root/'verified-package/Scripts').exists()
for p in [a/'Contents/MacOS/BostoTablet',root/'BostoTablet.pkg']:
    print(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p} ({p.stat().st_size} bytes)')
print('Verified arm64 app, identity, nonrelocatable /Applications payload, byte equality, no scripts or extra binaries.')
PY
