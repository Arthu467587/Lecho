"""Exercise the Bash packager with simulated macOS tools, never an Apple build."""
from pathlib import Path
import os, plistlib, subprocess, tempfile, unittest, zipfile

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'scripts/build-sideload-ipa.sh'
SH = Path(os.environ.get('LECHO_TEST_BASH', '/bin/bash' if os.name != 'nt' else 'bash'))
PYTHON = os.environ.get('LECHO_TEST_PYTHON', os.sys.executable)

BRIDGE = r'''
from pathlib import Path
import datetime,hashlib,json,os,plistlib,shutil,sys,zipfile
root=Path(os.environ['LECHO_FIXTURE_ROOT']).resolve()
def path(s):
    if len(s)>2 and s[0]=='/' and s[2]=='/' and s[1].isalpha(): s=s[1]+':'+s[2:]
    p=Path(s).resolve()
    assert p.is_relative_to(root),(p,root)
    return p
tool=sys.argv[1];args=sys.argv[2:]
if tool=='mkdir':path(args[-1]).mkdir(parents=True,exist_ok=True)
elif tool=='date':print('20261027-120000')
elif tool=='xcodebuild':
    if args==['-version']: print('SIMULATED Xcode');sys.exit(0)
    (root/'unexpected-build-called').write_text('yes');print('SIMULATED BUILD FAILURE');sys.exit(65)
elif tool=='plutil':
    p=path(args[-1]);obj=plistlib.loads(p.read_bytes())
    if args[0]=='-lint':sys.exit(0)
    if args[0]=='-extract':
        value=obj
        for k in args[1].split('.'):value=value[int(k)] if isinstance(value,list) else value[k]
        print(value)
    else:
        assert args[0] in ['-replace','-insert']
        value=json.loads(args[3]) if args[2]=='-json' else args[3]
        obj[args[1]]=value;p.write_bytes(plistlib.dumps(obj))
elif tool=='xcrun':
    if args[0]=='lipo': print(os.environ.get('LECHO_FIXTURE_ARCH','arm64'))
    elif args[0]=='vtool':print('Load command 0\n      cmd LC_BUILD_VERSION\n platform '+os.environ.get('LECHO_FIXTURE_PLATFORM','IOS')+'\n    minos 26.0')
    else:raise AssertionError(args)
elif tool=='ditto':
    src,dst=map(path,args[-2:])
    if '-c' not in args:shutil.copytree(src,dst)
    else:
        with zipfile.ZipFile(dst,'w') as z:
            for f in src.rglob('*'):
                if f.is_file():z.write(f,f.relative_to(src.parent).as_posix())
elif tool=='unzip':
    p=path(args[1])
    if os.environ.get('LECHO_FIXTURE_ZIPFAIL')=='1':sys.exit(2)
    with zipfile.ZipFile(p) as z:
        if args[0]=='-p':sys.stdout.buffer.write(z.read(args[2]))
        else:assert z.testzip() is None
elif tool=='shasum':
    p=path(args[-1]);print(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p))
elif tool=='mv':path(args[0]).rename(path(args[1]))
elif tool=='tail':print('SIMULATED compiler failure log')
else:raise AssertionError(tool)
'''

WRAPPER = r'''#!/bin/bash
function dirname() { printf '%s\n' "${1%/*}"; }
function uname() { printf '%s\n' Darwin; }
function open() { return 0; }
'''+''.join(f'function {tool}() {{ "$LECHO_TEST_PYTHON" "$LECHO_TEST_BRIDGE" {tool} "$@"; }}\n'
           for tool in ['mkdir','date','xcodebuild','plutil','xcrun','ditto','unzip','shasum','mv','tail'])+r'''
export -f dirname uname open mkdir date xcodebuild plutil xcrun ditto unzip shasum mv tail
"$BASH" "$@"
'''

class IpaBuilderChecks(unittest.TestCase):
    def setUp(self):
        (ROOT/'work').mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(prefix='ipa-builder-',dir=ROOT/'work')
        self.base=Path(self.tmp.name).resolve()
        self.project=self.base/'input project';self.project.mkdir()
        (self.project/"L'écho.xcodeproj").mkdir()
        (self.project/"L'écho.xcodeproj/project.pbxproj").write_text('{}')
        (self.base/'tools.py').write_text(BRIDGE,encoding='utf-8')
        (self.base/'run.sh').write_bytes(WRAPPER.encode('utf-8'))
        self.env=os.environ.copy()
        self.env.update(LECHO_TEST_PYTHON=str(PYTHON),LECHO_TEST_BRIDGE=(self.base/'tools.py').as_posix(),LECHO_FIXTURE_ROOT=self.base.as_posix())
    def tearDown(self):
        assert self.base.is_relative_to((ROOT/'work').resolve()) and self.base.name.startswith('ipa-builder-')
        self.tmp.cleanup()
    def app(self,name="L'e\u0301cho"):
        app=self.project/"work/Sideload-old/DerivedData/Build/Products/Release-iphoneos/L'écho.app"
        app.mkdir(parents=True)
        self.original=app/'Info.plist'
        self.original.write_bytes(plistlib.dumps({'CFBundleExecutable':'LechoDevice','CFBundleShortVersionString':'1.3.0',
            'CFBundleSupportedPlatforms':['iPhoneOS'],'DTPlatformName':'iphoneos','CFBundleIdentifier':'org.clairtest.LocalSpeech',
            'CFBundleDisplayName':name,'CFBundleName':name}))
        (app/'LechoDevice').write_bytes(b'SIMULATED device executable; not a Mach-O')
        return app
    def run_builder(self):
        return subprocess.run([str(SH),str(self.base/'run.sh'),SCRIPT.as_posix(),'--project-root',self.project.as_posix(),'--reuse-latest'],
            cwd=ROOT,env=self.env,capture_output=True,text=True,encoding='utf-8')
    def archive(self):
        files=list(self.project.glob('work/Sideload-*/*.ipa'));self.assertEqual(len(files),1);return files[0]
    def test_reuse_unicode_normalization_keeps_source_and_builds_payload(self):
        self.app();before=self.original.read_bytes();p=self.run_builder();self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertFalse((self.base/'unexpected-build-called').exists())
        self.assertEqual(self.original.read_bytes(),before)
        with zipfile.ZipFile(self.archive()) as z:
            data=plistlib.loads(z.read("Payload/L'écho.app/Info.plist"))
            self.assertEqual(data['CFBundleDisplayName'],"L'écho")
            self.assertEqual(data['CFBundleIdentifier'],'org.clairtest.LocalSpeech')
            self.assertEqual(data['CFBundleSupportedPlatforms'],['iPhoneOS'])
    def test_display_name_drift_is_normalized_on_copy_only(self):
        self.app('Clair');p=self.run_builder();self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(plistlib.loads(self.original.read_bytes())['CFBundleName'],'Clair')
        with zipfile.ZipFile(self.archive()) as z:self.assertEqual(plistlib.loads(z.read("Payload/L'écho.app/Info.plist"))['CFBundleName'],"L'écho")
    def test_arm64_simulator_is_rejected_by_binary_platform(self):
        self.app();self.env['LECHO_FIXTURE_PLATFORM']='IOSSIMULATOR';p=self.run_builder()
        self.assertNotEqual(p.returncode,0);self.assertIn('IOSSIMULATOR',p.stdout+p.stderr)
        self.assertFalse(list(self.project.glob('work/Sideload-*/*.ipa')))
    def test_wrong_architecture_is_rejected(self):
        self.app();self.env['LECHO_FIXTURE_ARCH']='x86_64';p=self.run_builder()
        self.assertNotEqual(p.returncode,0);self.assertIn('arm64',p.stdout+p.stderr)
        self.assertFalse(list(self.project.glob('work/Sideload-*/*.ipa')))
    def test_no_existing_app_does_not_silently_rebuild(self):
        p=self.run_builder();self.assertNotEqual(p.returncode,0)
        self.assertIn('未找到',p.stdout+p.stderr);self.assertFalse((self.base/'unexpected-build-called').exists())
    def test_crc_failure_never_publishes_an_ipa(self):
        self.app();self.env['LECHO_FIXTURE_ZIPFAIL']='1';p=self.run_builder()
        self.assertNotEqual(p.returncode,0);self.assertFalse(list(self.project.glob('work/Sideload-*/*.ipa')))
        self.assertEqual(len(list(self.project.glob('work/Sideload-*/*.ipa.partial'))),1,
                         'Reach ZIP validation rather than fail at an unrelated earlier guard')
        self.assertNotIn('IPA 已生成',p.stdout)

if __name__=='__main__':unittest.main(verbosity=2)
