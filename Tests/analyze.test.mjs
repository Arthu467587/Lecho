import test from 'node:test';
import assert from 'node:assert/strict';
import { tokens, alignWords, quantile, summarize, markdown } from '../scripts/analyze.mjs';

test('French normalization handles typography but retains accents', () => {
  assert.deepEqual(tokens("L’injectivité n'est PAS nécessaire."), ['l', 'injectivité', 'n', 'est', 'pas', 'nécessaire']);
  assert.equal(alignWords('Énergie, mécanique !', 'énergie mécanique').wer, 0);
  assert.notEqual(alignWords('énergie', 'energie').wer, 0);
});
test('WER records substitutions, deletions, insertions and permits > 100%', () => {
  const a = alignWords('la force est nulle', 'la force reste');
  assert.equal(a.errors, 2); assert.equal(a.wer, 0.5);
  const b = alignWords('force', 'la force est toujours nulle');
  assert.equal(b.insertions, 4); assert.equal(b.wer, 4);
  assert.equal(alignWords('', 'quelque chose'), null);
  assert.equal(alignWords('pas nul', '').deletions, 2);
});
test('oral numbers are flagged instead of silently equated with digits', () => {
  assert.equal(alignWords('deux kilogrammes', '2 kilogrammes').substitutions, 1);
});
test('percentiles filter invalid numbers and use nearest-rank', () => {
  assert.equal(quantile([.1, .3, .2, NaN, null], .5), .2);
  assert.equal(quantile([.1, .3, .2], .95), .3);
  assert.equal(quantile([], .95), null);
});
function fixture() {
  return { schemaVersion: 1, sampleName: 'logic', source: 'synthetic-unit-test', status: 'complete',
    systemVersion: 'not-a-device', durationSeconds: 3, reference: 'la force ne travaille pas',
    finalizedTranscript: 'la force travaille', criticalTerms: ['force', 'fort'],
    lines: [{ isFinal: true }, { isFinal: false }], events: [
      { isFinal: false, deliveryLagSeconds: .2, afterStop: false },
      { isFinal: true, deliveryLagSeconds: .5, afterStop: false },
      { isFinal: true, deliveryLagSeconds: 99, afterStop: true },
      { isFinal: false, deliveryLagSeconds: -.2, afterStop: false }
    ], meterSamples: [{ conversionQueueSeconds: .01, thermalState: 1 }] };
}
test('summary excludes flush events, flags negation, never scores drafts', () => {
  const s = summarize(fixture());
  assert.equal(s.partial.p95, .2); assert.equal(s.final.p95, .5);
  assert.equal(s.excludedStopFlushEvents, 1); assert.equal(s.unfinalizedRows, 1);
  assert.equal(s.negativeLagEvents, 1); assert.equal(s.scoring.deletions, 2);
  assert.equal(s.criticalEdits.length, 2);
  assert.equal(s.terms[0].recognizedOccurrences, 1);
  assert.equal(s.terms[1].recognizedOccurrences, 0);
  assert.match(markdown(s), /40\.00%/);
});
test('missing reference and invalid schema never produce a fake accuracy', () => {
  const r = fixture(); r.reference = '';
  const s = summarize(r);
  assert.equal(s.scoring, null); assert.equal(s.terms[0].expectedOccurrences, null);
  assert.match(markdown(s), /无法计算/);
  assert.throws(() => summarize({ schemaVersion: 2 }), /schemaVersion/);
});
test('externally verified reference overrides the originally selected passage', () => {
  assert.equal(summarize(fixture(), 'la force travaille').scoring.wer, 0);
});

test('cloud timings exclude failed and cancelled attempts and expose unfinished units', () => {
  const r = fixture(); r.cloudProvider = 'DeepSeek';
  r.translationAttempts = [
    { status: 'complete', requestedAtSeconds: 10, firstContentAtSeconds: 11, completedAtSeconds: 12, inputTokens: 10, outputTokens: 5 },
    { status: 'failed', requestedAtSeconds: 20, firstContentAtSeconds: 25, completedAtSeconds: 30 },
    { status: 'cancelled', requestedAtSeconds: 40, completedAtSeconds: 41 }
  ];
  r.chineseCaptions = [{ status: 'complete' }, { status: 'cancelled' }];
  const s = summarize(r);
  assert.equal(s.cloud.firstContentP95, 1); assert.equal(s.cloud.completionP95, 2);
  assert.equal(s.cloud.failed, 1); assert.equal(s.cloud.cancelled, 1);
  assert.equal(s.cloud.unfinishedUnits, 1); assert.equal(s.cloud.inputTokens, 10);
  assert.match(markdown(s), /不含说话/);
});
test('legacy local reports do not fabricate cloud timing data', () => {
  assert.equal(summarize(fixture()).cloud, null);
});
