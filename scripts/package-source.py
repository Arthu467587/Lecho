from pathlib import Path
import argparse,hashlib,json,plistlib,re,zipfile,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--sideload',action='store_true');args=p.parse_args()
output=Path(args.output).resolve()
version='1.3.0'
suffix='-sideload-source' if args.sideload else ''
assert output.name==f'Lecho-iPad-{version}{suffix}.zip', 'Use the current versioned filename'
assert not output.exists(), 'Preserve existing deliveries; choose a new version'
project=(ROOT/"L'écho.xcodeproj/project.pbxproj").read_text(encoding='utf-8')
assert re.findall(r'MARKETING_VERSION = ([^;]+);',project)==[version,version]
assert re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);',project)==['130','130']
assert project.count('INFOPLIST_KEY_CFBundleDisplayName = "L\'écho";')==2
assert project.count('INFOPLIST_KEY_CFBundleName = "L\'écho";')==2
assert project.count('PRODUCT_NAME = "L\'écho"; PRODUCT_MODULE_NAME = Lecho;')==2
assert not (ROOT/'Clair.xcodeproj').exists(), 'Do not deliver a second old project'
files=sorted(f for f in ROOT.rglob('*') if f.is_file() and not any(part in {'.git','.superpowers','work','__pycache__'} for part in f.relative_to(ROOT).parts))
for f in files:
 assert f.suffix not in {'.ipa','.caf','.wav','.m4a','.pem','.enc','.zip'} and not f.name.startswith('.env'),f.name
 if f.suffix in {'.swift','.mjs','.json','.md','.txt','.sh','.py','.pbxproj'}:assert not re.search(r'\bsk-[a-zA-Z0-9_-]{16,}\b',f.read_text(encoding='utf-8')),f.name
for scheme in ROOT.rglob('*.xcscheme'):ET.parse(scheme)
assert b'\r' not in (ROOT/'scripts/check-mac.sh').read_bytes(), 'Mac shell script needs LF newlines'
assert b'\r' not in (ROOT/'scripts/build-sideload-ipa.sh').read_bytes(), 'IPA build script needs LF newlines'
assert plistlib.loads((ROOT/'Sources/Info.plist').read_bytes())['UIBackgroundModes']==['audio']
assert plistlib.loads((ROOT/'Sources/PrivacyInfo.xcprivacy').read_bytes())['NSPrivacyTracking'] is False
sources='\n'.join(f.read_text(encoding='utf-8') for f in (ROOT/'Sources').glob('*.swift'))
assert re.findall(r'https://[^"\s]+',sources)==['https://api.deepseek.com/chat/completions']
assert sum('@main' in f.read_text(encoding='utf-8') for f in (ROOT/'Sources').glob('*.swift'))==1
output.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
 for f in files:
  info=zipfile.ZipInfo('Lecho/'+f.relative_to(ROOT).as_posix());info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=(0o100755 if f.suffix=='.sh' else 0o100644)<<16;z.writestr(info,f.read_bytes())
with zipfile.ZipFile(output) as z:
 assert z.testzip() is None and len(z.namelist())==len(files)
 for f in files:assert z.read('Lecho/'+f.relative_to(ROOT).as_posix())==f.read_bytes()
print(json.dumps({'version':version,'archive':str(output),'files':len(files),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'sourceOnly':True,'archiveIntegrity':'passed','infoPlist':'passed','credentialScan':'passed','xcode':'not-run','signedIPA':False},ensure_ascii=False,indent=2))
