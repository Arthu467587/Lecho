import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const source = name => fs.readFileSync(new URL('../Sources/'+name,import.meta.url),'utf8');

// Wiring checks only. The corresponding behavioral assertions live in main.swift.
test('continuous-speech review and capacity locking use the same stable final prefix',()=>{
  const s=source('SemanticSegmentation.swift');
  assert.match(s,/func reviewableCount\(now: Double\) -> Int/);
  assert.match(s,/candidates\.prefix\s*\{[\s\S]*?\.isFinal[\s\S]*?>= 1\.0[\s\S]*?\}\.count/);
  assert.match(s,/let readyCount = reviewableCount\(now: now\)/);
  assert.match(s,/cursor <= readyCount - 3/);
  const window=s.slice(s.indexOf('func reviewWindow'),s.indexOf('mutating func apply'));
  assert.match(window,/reviewableCount\(now: now\)/);
  assert.doesNotMatch(window,/candidates\.count-3/);
});

test('late final speech is rebuilt locally after stop and at background expiry',()=>{
  const c=source('ClassroomController.swift');
  const stop=c.slice(c.indexOf('private func finishClass'),c.indexOf('@discardableResult private func completeFinalSave'));
  assert.ok(stop.indexOf('await capture.stop()') < stop.indexOf('translator.flushSegmentation(finalLines: lines)'));
  assert.match(stop,/translator\.flushSegmentation\(finalLines: lines\)/);
  const expiry=c.slice(c.indexOf('expirationHandler:'),c.indexOf('private func endBackgroundSave'));
  assert.ok(expiry.indexOf('self.translator.cancel()') < expiry.indexOf('self.translator.flushSegmentation(finalLines: self.lines)'));
  assert.ok(expiry.indexOf('self.translator.flushSegmentation(finalLines: self.lines)') < expiry.indexOf('self.saveNow()'));
  const t=source('DeepSeekTranslation.swift');
  const flush=t.slice(t.indexOf('func flushSegmentation'),t.indexOf('/// Build a recoverable'));
  assert.match(flush,/finalLines: \[CaptionLine\]\? = nil/);
  assert.match(flush,/latestLines = finalLines/);
  assert.match(flush,/rebuildSegmentation\(flush: true\)/);
  assert.doesNotMatch(flush,/\bpump\(|\bbegin\(|accepting = true|liveSession = true/);
});
