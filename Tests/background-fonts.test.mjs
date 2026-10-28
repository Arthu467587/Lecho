import {test} from 'node:test';
import assert from 'node:assert/strict';import fs from 'node:fs';
const source=n=>fs.readFileSync(new URL('../Sources/'+n,import.meta.url),'utf8');
test('live and review read one persisted caption-size key and expose the shared controls',()=>{
 for(const file of ['LechoApp.swift','ClassReviewView.swift']){const s=source(file);assert.match(s,/@AppStorage\(CaptionAppearance.storageKey\)/);assert.match(s,/CaptionFontControl\(size: \$fontSize\)/);}
 assert.match(source('AppSettingsView.swift'),/CaptionFontControl/);
});
test('background audio is declared as an Info.plist array and both Xcode configs consume it',()=>{
 const p=source('Info.plist');assert.match(p,/<key>UIBackgroundModes<\/key>\s*<array>\s*<string>audio<\/string>/);
 const project=fs.readFileSync(new URL("../L'écho.xcodeproj/project.pbxproj",import.meta.url),'utf8');assert.equal((project.match(/INFOPLIST_FILE = Sources\/Info.plist/g)||[]).length,2);
});
test('scene changes route to lifecycle handling rather than unconditional stop',()=>{
 const app=source('LechoApp.swift');assert.match(app,/classroom.applicationDidEnterBackground\(\)/);assert.match(app,/classroom.applicationDidBecomeActive\(\)/);assert.doesNotMatch(app,/stopForBackground/);
 const controller=source('ClassroomController.swift');assert.match(controller,/ClassroomLifecycle.backgroundAction/);assert.match(controller,/case \.continueMicrophone:/);assert.match(controller,/case \.pauseImportedFile:/);assert.match(controller,/capture.cancelPreparation\(\)/);assert.match(controller,/applicationState != \.background/);
});
test('locked live requests use an in-memory run key and cancel clears it without weakening Keychain',()=>{
 const s=source('DeepSeekTranslation.swift');const perform=s.slice(s.indexOf('private func perform'),s.indexOf('private func update'));assert.match(perform,/runKey/);assert.match(s,/runKey = nil/);assert.match(s,/allowBackground: Bool = false/);assert.match(s,/kSecAttrAccessibleWhenUnlockedThisDeviceOnly/);assert.doesNotMatch(s,/kSecAttrAccessibleAfterFirstUnlock/);
 assert.match(source('ClassroomController.swift'),/translator.restore\(seed, allowBackground: doc.source == "microphone", live: true\)/);
});
test('class atomic writes and recordings explicitly support locked-device access after first unlock',()=>{
 assert.match(source('ClassLibrary.swift'),/completeFileProtectionUntilFirstUserAuthentication/);assert.match(source('LocalSpeechCapture.swift'),/completeUntilFirstUserAuthentication/);
});
test('audio observers discriminate interruption begin and actual input route changes',()=>{
 const s=source('LocalSpeechCapture.swift');assert.match(s,/type == \.began/);assert.match(s,/ClassroomLifecycle.inputRouteChanged/);assert.match(s,/CancellationError/);
});

test('stop/save holds a finite background lease and expiration saves and clears pending work',()=>{
 const c=source('ClassroomController.swift');assert.ok(c.includes('beginBackgroundSaveIfNeeded()'),'Missing bounded stop/save lease');assert.ok(c.includes('endBackgroundSave()'),'Missing end of lease');assert.ok(c.includes('expirationHandler:'),'Missing expiry handling');assert.ok(c.includes('capture.cancelFinalization()'),'Expiry must cancel remaining recognition finalization');
});
test('only microphone classes retain credentials for lock-screen translation',()=>{
 assert.ok(source('ClassroomController.swift').includes('translator.restore(seed, allowBackground: doc.source == "microphone", live: true)'));
});
test('file delivery rechecks pause after every timed wait, including the final buffer',()=>{
 const s=source('LocalSpeechCapture.swift');const index=s.indexOf('while true {');assert.ok(index>=0,'Missing pause-aware delivery loop');const loop=s.slice(index,s.indexOf('sink.accept(buffer)',index));assert.ok(loop.includes('if paused'),'The delivery wait must observe pause');assert.ok(loop.includes('min(wait, 0.05)'),'Use bounded waits so background pause can be observed');
});
test('current delivery documentation does not imply unavailable Swift syntax checks ran',()=>{
 const readme=fs.readFileSync(new URL('../README-先读这里.md',import.meta.url),'utf8');assert.ok(!readme.includes('已完成工程结构、Swift 语法'));
});
