import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const source=n=>fs.readFileSync(new URL('../Sources/'+n,import.meta.url),'utf8');
test('chained pending merges keep explicit full provisional coverage',()=>{
 const c=source('TranslationCore.swift'),t=source('DeepSeekTranslation.swift');
 assert.ok(c.includes('var provisionalFrench: String?'));
 assert.ok(c.includes('func coversProvisionalSource'));
 assert.ok(c.includes('row.coversProvisionalSource(part.text)'));
 assert.ok(t.includes('row.provisionalFrench = slice.french'));
});
test('splitting a reviewed merge restores cached complete component translations',()=>{
 const c=source('TranslationCore.swift'),t=source('DeepSeekTranslation.swift');
 assert.ok(c.includes('func completed(for slice: TranslationSlice)'));
 assert.ok(t.includes('firstPass.completed(for: slice)'));
 assert.ok(t.includes('for row in captions where row.status == "complete"'));
});
test('persisted merged repair identity and streaming preservation do not depend on a fresh plan submission',()=>{
 const c=source('TranslationCore.swift'),t=source('DeepSeekTranslation.swift');
 assert.ok(c.includes('var isSemanticRepair: Bool'));
 assert.ok(t.includes(String.raw`Set(captions.filter(\.isSemanticRepair).map(\.id))`));
 assert.ok(t.includes('let preserveProvisional = item.secondaryRepair'));
 assert.ok(t.includes('$0.provisionalFrench = nil'));
});
test('real source corrections keep primary priority while only semantic repairs occupy the revision slot',()=>{
 const c=source('TranslationCore.swift'),t=source('DeepSeekTranslation.swift');
 assert.ok(c.includes('secondaryIDs: Set<String> = []'));
 assert.ok(c.includes('guard allowRevisions || !item.secondaryRepair'));
 assert.ok(t.includes('if item.secondaryRepair { revisionTasks.insert(id) }'));
});
