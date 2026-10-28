#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export function tokens(text) {
  // Case/punctuation independent, accents retained, apostrophes and hyphens split.
  // Spoken numbers and digits are NOT silently treated as equivalent.
  return (text.normalize('NFC').toLocaleLowerCase('fr')
    .replace(/[’'ʼ\-‐‑]/gu, ' ').match(/[\p{L}\p{N}]+(?:[.,]\p{N}+)?/gu) ?? []);
}

export function alignWords(reference, hypothesis) {
  const a = tokens(reference), b = tokens(hypothesis);
  if (!a.length) return null;
  if (a.length * b.length > 25_000_000) {
    throw new Error('参考与转写过长，请按 10–20 分钟拆分评分，避免占用过多内存。');
  }
  const width = b.length + 1;
  const costs = new Uint32Array((a.length + 1) * width);
  for (let i = 0; i <= a.length; i++) costs[i * width] = i;
  for (let j = 0; j <= b.length; j++) costs[j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      costs[i * width + j] = Math.min(
        costs[(i - 1) * width + j - 1] + Number(a[i - 1] !== b[j - 1]),
        costs[(i - 1) * width + j] + 1,
        costs[i * width + j - 1] + 1);
    }
  }
  let i = a.length, j = b.length, substitutions = 0, deletions = 0, insertions = 0;
  const edits = [];
  while (i || j) {
    const value = costs[i * width + j];
    if (i && j && value === costs[(i - 1) * width + j - 1] + Number(a[i - 1] !== b[j - 1])) {
      if (a[i - 1] !== b[j - 1]) {
        substitutions++; edits.push({ type: 'substitution', referenceWord: a[i - 1], heardWord: b[j - 1], referenceIndex: i - 1 });
      }
      i--; j--;
    } else if (i && value === costs[(i - 1) * width + j] + 1) {
      deletions++; edits.push({ type: 'deletion', referenceWord: a[i - 1], heardWord: '', referenceIndex: i - 1 }); i--;
    } else {
      insertions++; edits.push({ type: 'insertion', referenceWord: '', heardWord: b[j - 1], referenceIndex: i }); j--;
    }
  }
  const errors = substitutions + deletions + insertions;
  return { referenceWords: a.length, hypothesisWords: b.length, substitutions, deletions, insertions,
    errors, wer: errors / a.length, edits: edits.reverse() };
}

export function quantile(input, p) {
  const a = input.filter(x => typeof x === 'number' && Number.isFinite(x)).sort((x, y) => x - y);
  return a.length ? a[Math.max(0, Math.ceil(a.length * Math.min(1, Math.max(0, p))) - 1)] : null;
}

function termOccurrences(text, term) {
  const input = tokens(text), phrase = tokens(term);
  if (!phrase.length) return 0;
  let count = 0;
  for (let i = 0; i <= input.length - phrase.length; i++) {
    if (phrase.every((word, offset) => input[i + offset] === word)) count++;
  }
  return count;
}

export function summarize(report, overrideReference) {
  if (report.schemaVersion !== 1 || !Array.isArray(report.events) || !Array.isArray(report.lines)) {
    throw new Error('不是支持的 ClairLocalTest schemaVersion=1 报告。');
  }
  const reference = overrideReference ?? report.reference ?? '';
  // Score only finalized text. Drafts retained in the raw report are never called final accuracy.
  const hypothesis = report.finalizedTranscript ?? report.lines.filter(l => l.isFinal).map(l => l.text).join(' ');
  const live = report.events.filter(e => !e.afterStop);
  const lag = final => live.filter(e => e.isFinal === final)
    .map(e => e.deliveryLagSeconds).filter(x => typeof x === 'number' && Number.isFinite(x) && x >= 0);
  const partial = lag(false), final = lag(true);
  const scoring = alignWords(reference, hypothesis);
  const criticalEdits = scoring?.edits.filter(e =>
    /^(ne|n|pas|non|sans|tout|tous|toute|toutes|existe|nécessaire|suffisante|moins|plus|égal|égale|inférieur|supérieur)$/u.test(e.referenceWord)
    || /\p{N}/u.test(e.referenceWord + e.heardWord)) ?? [];
  const attempts = report.translationAttempts ?? [];
  const complete = attempts.filter(a => a.status === 'complete');
  const firstContent = complete.filter(a => Number.isFinite(a.firstContentAtSeconds))
    .map(a => a.firstContentAtSeconds - a.requestedAtSeconds).filter(x => x >= 0);
  const cloud = Array.isArray(report.translationAttempts) ? {
    provider: report.cloudProvider, attempts: attempts.length, completed: complete.length,
    failed: attempts.filter(a => a.status === 'failed').length,
    cancelled: attempts.filter(a => a.status === 'cancelled').length,
    firstContentP50: quantile(firstContent, .5), firstContentP95: quantile(firstContent, .95),
    completionP50: quantile(complete.map(a => a.completedAtSeconds - a.requestedAtSeconds), .5),
    completionP95: quantile(complete.map(a => a.completedAtSeconds - a.requestedAtSeconds), .95),
    units: report.chineseCaptions?.length ?? 0,
    unfinishedUnits: (report.chineseCaptions ?? []).filter(c => c.status !== 'complete').length,
    inputTokens: attempts.reduce((n,a) => n + (a.inputTokens ?? 0), 0),
    outputTokens: attempts.reduce((n,a) => n + (a.outputTokens ?? 0), 0)
  } : null;
  return {
    sampleName: report.sampleName, source: report.source, status: report.status,
    systemVersion: report.systemVersion, durationSeconds: report.durationSeconds,
    scoring, cloud, unfinalizedRows: report.lines.filter(l => !l.isFinal).length,
    partial: { count: partial.length, p50: quantile(partial, .5), p95: quantile(partial, .95) },
    final: { count: final.length, p50: quantile(final, .5), p95: quantile(final, .95) },
    negativeLagEvents: live.filter(e => typeof e.deliveryLagSeconds === 'number' && e.deliveryLagSeconds < 0).length,
    excludedStopFlushEvents: report.events.filter(e => e.afterStop).length,
    maxConversionQueueSeconds: Math.max(0, ...(report.meterSamples ?? []).map(x => x.conversionQueueSeconds).filter(Number.isFinite)),
    peakThermalState: Math.max(0, ...(report.meterSamples ?? []).map(x => x.thermalState).filter(Number.isFinite)),
    terms: (report.criticalTerms ?? []).map(term => ({ term,
      expectedOccurrences: reference.trim() ? termOccurrences(reference, term) : null,
      recognizedOccurrences: termOccurrences(hypothesis, term) })),
    criticalEdits,
    limitations: [
      'WER requires a human-verified verbatim reference of what was actually said. It is not a percentage of semantic correctness.',
      'Punctuation and case are ignored; accents are retained, apostrophes/hyphens split. Spoken numbers and mathematical notation need manual review.',
      'Delivery lag is approximate and event-weighted. Stop-flush events are excluded. These values exclude UI rendering and Chinese translation.',
      'Confidence scores and term matches are not proof of accuracy. No reference means WER is unavailable.',
      'Critical-word flags are a heuristic review list, not a complete check of negation, quantifiers, formulas or units.'
    ]
  };
}

export function markdown(s) {
  const fmt = x => x == null ? '无数据' : `${x.toFixed(3)} 秒`;
  const safe = x => String(x ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
  const lines = ['# Clair 本地转写测试报告', '', `样本：${safe(s.sampleName || '未命名')}`,
    `来源：${s.source}；状态：${s.status}；iPadOS：${s.systemVersion}；音频：${s.durationSeconds.toFixed(1)} 秒`, '',
    '| 结果送达延迟 | 事件数 | 中位数 | P95 |', '|---|---:|---:|---:|',
    `| 临时文字 | ${s.partial.count} | ${fmt(s.partial.p50)} | ${fmt(s.partial.p95)} |`,
    `| 最终确认 | ${s.final.count} | ${fmt(s.final.p50)} | ${fmt(s.final.p95)} |`, '',
    `结束时补出的事件 ${s.excludedStopFlushEvents} 次，未最终确认的字幕 ${s.unfinalizedRows} 行。`,
    `负延迟事件 ${s.negativeLagEvents} 次（需检查时钟）；最高 thermalState=${s.peakThermalState}（0 正常，1 轻度，2 严重，3 临界）。`, ''];
  if (s.scoring) {
    const w = s.scoring;
    lines.push(`词错误率 WER：**${(w.wer * 100).toFixed(2)}%**；参考 ${w.referenceWords} 词，替换 ${w.substitutions}、漏词 ${w.deletions}、多词 ${w.insertions}。`,
      'WER 越低越好。它可能超过 100%，不能直接称为语义准确率。', '');
  } else lines.push('**没有人工核对的参考原文，无法计算 WER 或识别准确率。**', '');
  if (s.cloud) {
    const c = s.cloud;
    lines.push('## 中文字幕接口延迟', '',
      `服务：${safe(c.provider)}；请求 ${c.attempts} 次，完成 ${c.completed}、失败 ${c.failed}、取消 ${c.cancelled}。`,
      `请求→首批中文：中位数 ${fmt(c.firstContentP50)}，P95 ${fmt(c.firstContentP95)}。`,
      `请求→完整响应：中位数 ${fmt(c.completionP50)}，P95 ${fmt(c.completionP95)}。`,
      `当前字幕片段 ${c.units} 段，未完成 ${c.unfinishedUnits} 段。收到的用量统计：输入 ${c.inputTokens}、输出 ${c.outputTokens} tokens（取消或断流请求的用量可能未收到）。`,
      '这些是请求后收到内容的时间，不含说话、识别、等待分句与屏幕渲染，不能当作端到端中文字幕延迟或翻译准确率。', '');
  }
  if (s.terms.length) {
    lines.push('| 重点词 | 参考出现次数 | 识别出现次数 |', '|---|---:|---:|');
    for (const t of s.terms) lines.push(`| ${safe(t.term)} | ${t.expectedOccurrences ?? '无参考'} | ${t.recognizedOccurrences} |`);
    lines.push('', '出现次数相同也可能在错误位置出现，需要回听核对。', '');
  }
  if (s.scoring?.edits.length) {
    lines.push('## 逐词差异（最多列出 150 处）', '', '| 类型 | 参考词 | 识别词 | 参考词序号（从 1 起） |', '|---|---|---|---:|');
    for (const e of s.scoring.edits.slice(0, 150)) lines.push(`| ${e.type} | ${safe(e.referenceWord)} | ${safe(e.heardWord)} | ${e.referenceIndex + 1} |`);
    lines.push('');
  }
  lines.push('## 解释限制', '', ...s.limitations.map(x => `- ${x}`), '');
  return lines.join('\n');
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    const [reportPath, referencePath] = process.argv.slice(2);
    if (!reportPath) throw new Error('用法：node scripts/analyze.mjs report.json [人工核对后的法语原文.txt]');
    const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
    const summary = summarize(report, referencePath ? fs.readFileSync(referencePath, 'utf8') : undefined);
    const base = path.join(path.dirname(path.resolve(reportPath)), 'analysis');
    fs.writeFileSync(base + '.json', JSON.stringify(summary, null, 2) + '\n');
    fs.writeFileSync(base + '.md', markdown(summary));
    console.log(`已写入 ${base}.md 和 ${base}.json`);
    console.log(summary.scoring ? `WER ${(summary.scoring.wer * 100).toFixed(2)}%（需人工核对参考原文）` : '无参考原文，未计算准确率。');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
