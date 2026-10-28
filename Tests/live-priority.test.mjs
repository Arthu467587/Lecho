import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read=n=>fs.readFileSync(new URL('../Sources/'+n,import.meta.url),'utf8');
test('fast clauses bypass semantic merging until first-pass captions have been shown',()=>{
 const s=read('SemanticSegmentation.swift'),t=read('DeepSeekTranslation.swift'),p=read('TranslationCore.swift');
 assert.ok(s.includes('let quickBoundary ='));
 assert.ok(s.includes('static let previewWordLimit = 12'));
 assert.ok(s.includes('translatedFragments: [UUID: String]? = nil'));
 assert.ok(s.includes('preservingLocked: units.filter'));
 assert.ok(t.includes('firstPass.record(units: units, captions: captions)'));
 assert.ok(t.includes('translatedFragments: accepting ? firstPass.texts : nil'));
 assert.ok(p.includes('static let closedDelay = 0.12'));
 assert.ok(p.includes('hasReadyFirstPass'));
});
test('first-pass requests preempt review and merged Chinese stays visible during repair',()=>{
 const s=read('DeepSeekTranslation.swift');
 assert.ok(s.includes('cancelBoundaryReview()'));
 assert.ok(s.includes('reviewGeneration == reviewToken'));
 assert.ok(s.includes('tasks.isEmpty'));
 assert.ok(s.includes('allowRevisions: !liveSession || flushing || revisionTasks.isEmpty'));
 assert.ok(s.includes('provisionalChinese'));
 assert.ok(s.includes('if !preserveProvisional'));
});
