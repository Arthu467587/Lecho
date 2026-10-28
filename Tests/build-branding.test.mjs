import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const root = new URL('../', import.meta.url);
const read = name => fs.readFileSync(new URL(name, root), 'utf8');

test('bare catch blocks never assign a message to the implicit immutable error', () => {
  const files=fs.readdirSync(new URL('Sources/',root)).filter(name=>name.endsWith('.swift'));
  for (const name of files) {
    const bad=/\bcatch\s*\{[^{}]*?(?<![.\w])error\s*=(?!=)/s.test(read('Sources/'+name));
    assert.ok(!bad, name+': assign error messages to self.error, not the caught error');
  }
});

test('Xcode project, target, scheme and product consistently use the requested app name', () => {
  const projectName="L'écho.xcodeproj";
  assert.ok(fs.existsSync(new URL(projectName+'/',root)), 'The Xcode project still has the old name');
  assert.ok(!fs.existsSync(new URL('Clair.xcodeproj/',root)), 'Do not ship a second old project');
  const p=read(projectName+'/project.pbxproj');
  assert.ok(p.includes('name = "L\'écho"; productName = "L\'écho";'));
  assert.equal((p.match(/PRODUCT_NAME = "L'écho";/g)||[]).length,2);
  assert.equal((p.match(/INFOPLIST_KEY_CFBundleName = "L'écho";/g)||[]).length,2);
  assert.equal((p.match(/INFOPLIST_KEY_CFBundleDisplayName = "L'écho";/g)||[]).length,2);
  assert.equal((p.match(/PRODUCT_MODULE_NAME = Lecho;/g)||[]).length,2);
  const s=read(projectName+"/xcshareddata/xcschemes/L'écho.xcscheme");
  assert.equal((s.match(/BuildableName="L'écho.app" BlueprintName="L'écho" ReferencedContainer="container:L'écho.xcodeproj"/g)||[]).length,3);
  assert.ok(read('Sources/LechoApp.swift').includes('struct LechoApp: App'));
});

test('renaming keeps the installed app identity, credentials and library location',()=>{
  const p=read("L'écho.xcodeproj/project.pbxproj");
  assert.equal((p.match(/PRODUCT_BUNDLE_IDENTIFIER = org\.clairtest\.LocalSpeech;/g)||[]).length,2);
  assert.ok(read('Sources/DeepSeekTranslation.swift').includes('"org.clairtest.deepseek"'));
  assert.ok(read('Sources/ClassLibrary.swift').includes('"ClairLibrary"'));
});
