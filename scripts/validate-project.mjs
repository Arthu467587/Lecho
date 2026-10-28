#!/usr/bin/env node
// Portable structural validation only. This does not replace an Apple-SDK build.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const input = fs.readFileSync(path.join(root, "L'écho.xcodeproj/project.pbxproj"), 'utf8');
let offset = 0;
function token() {
  for (;;) {
    while (/\s/u.test(input[offset] ?? '') && offset < input.length) offset++;
    if (input.startsWith('//', offset)) { const end = input.indexOf('\n', offset); offset = end < 0 ? input.length : end + 1; continue; }
    if (input.startsWith('/*', offset)) { const end = input.indexOf('*/', offset); if (end < 0) throw Error('Unclosed comment'); offset = end + 2; continue; }
    break;
  }
  if (offset >= input.length) return null;
  const ch = input[offset++];
  if ('{}()=;,'.includes(ch)) return { punctuation: ch };
  if (ch === '"') {
    let out = '';
    while (offset < input.length) {
      const c = input[offset++];
      if (c === '"') return { value: out };
      if (c === '\\') { if (offset >= input.length) throw Error('Invalid escape'); out += input[offset++]; }
      else out += c;
    }
    throw Error('Unclosed quoted string');
  }
  let out = ch;
  while (offset < input.length && !/[\s{}()=;,]/u.test(input[offset])) out += input[offset++];
  return { value: out };
}
let next = token();
function take(punctuation) {
  if (next?.punctuation !== punctuation) throw Error(`Expected ${punctuation} near offset ${offset}`);
  next = token();
}
function parse() {
  if (next?.punctuation === '{') {
    take('{'); const result = Object.create(null);
    while (next?.punctuation !== '}') {
      if (!next || !('value' in next)) throw Error('Expected dictionary key');
      const key = next.value; next = token(); take('=');
      if (key in result) throw Error(`Duplicate key ${key}`);
      result[key] = parse(); take(';');
    }
    take('}'); return result;
  }
  if (next?.punctuation === '(') {
    take('('); const a = [];
    while (next?.punctuation !== ')') {
      a.push(parse());
      if (next?.punctuation !== ')') take(',');
    }
    take(')'); return a;
  }
  if (!next || !('value' in next)) throw Error('Expected scalar');
  const result = next.value; next = token(); return result;
}
const project = parse();
if (next !== null) throw Error('Trailing data');
const objects = project.objects;
function walk(x) {
  if (typeof x === 'string' && /^[A-F0-9]{24}$/u.test(x) && !(x in objects)) throw Error(`Missing object reference ${x}`);
  if (Array.isArray(x)) x.forEach(walk);
  else if (x && typeof x === 'object') Object.values(x).forEach(walk);
}
walk(project);
if (objects[project.rootObject]?.isa !== 'PBXProject') throw Error('Missing PBXProject');
const appTargets = Object.values(objects).filter(o => o.isa === 'PBXNativeTarget');
if (appTargets.length !== 1 || appTargets[0].name !== "L'écho" || appTargets[0].productName !== "L'écho" ||
    objects[appTargets[0].productReference]?.path !== "L'écho.app") throw Error('Inconsistent application product branding');
const sources = Object.values(objects).filter(o => o.isa === 'PBXFileReference' && o.lastKnownFileType === 'sourcecode.swift');
for (const file of sources) {
  if (!fs.existsSync(path.join(root, 'Sources', file.path))) throw Error(`Missing source ${file.path}`);
}
for(const name of fs.readdirSync(path.join(root,'Sources')).filter(n=>n.endsWith('.swift'))) if(!sources.some(f=>f.path===name)) throw Error(`Swift file omitted from project: ${name}`);
const sourcePhases = Object.values(objects).filter(o => o.isa === 'PBXSourcesBuildPhase');
const builtFiles = sourcePhases.flatMap(p => p.files).map(id => objects[objects[id].fileRef].path);
for (const source of sources) if (!builtFiles.includes(source.path)) throw Error(`Source omitted from target: ${source.path}`);
if (new Set(builtFiles).size !== sources.length) throw Error('Duplicate/incorrect target membership');
const configs = Object.values(objects).filter(o => o.isa === 'XCBuildConfiguration' && o.buildSettings.GENERATE_INFOPLIST_FILE === 'YES');
if (configs.length !== 2) throw Error('Missing target build configurations');
for (const { buildSettings: s } of configs) {
  if (s.PRODUCT_NAME !== "L'écho" || s.INFOPLIST_KEY_CFBundleName !== "L'écho" ||
      s.INFOPLIST_KEY_CFBundleDisplayName !== "L'écho" || s.PRODUCT_MODULE_NAME !== 'Lecho') throw Error('Inconsistent build-configuration branding');
  if (!s.INFOPLIST_KEY_NSMicrophoneUsageDescription || !s.INFOPLIST_KEY_NSSpeechRecognitionUsageDescription) throw Error('Missing privacy purpose strings');
  if (s.INFOPLIST_FILE !== 'Sources/Info.plist') throw Error('Missing background Info.plist input');
  if (s.TARGETED_DEVICE_FAMILY !== '2') throw Error('Expected iPad target');
}
const scheme = fs.readFileSync(path.join(root, "L'écho.xcodeproj/xcshareddata/xcschemes/L'écho.xcscheme"), 'utf8');
for (const match of scheme.matchAll(/BlueprintIdentifier="([A-F0-9]{24})"/gu)) {
  if (objects[match[1]]?.isa !== 'PBXNativeTarget') throw Error('Scheme refers to absent target');
}
const swiftSources = sources.map(f => fs.readFileSync(path.join(root, 'Sources', f.path), 'utf8')).join('\n');
if (/import\s+(AppKit|ScreenCaptureKit|Translation)\b/u.test(swiftSources)) throw Error('Unexpected Mac/translation dependency');
if (/https:\/\/(?:api\.)?openai\.com/iu.test(swiftSources)) throw Error('Unexpected OpenAI endpoint');
if (!swiftSources.includes('https://api.deepseek.com/chat/completions')) throw Error('Missing expected DeepSeek endpoint');
if (/\bsk-[a-zA-Z0-9_-]{16,}\b/u.test(swiftSources)) throw Error('Secret-looking key in source');
if (!swiftSources.includes('kSecAttrAccessibleWhenUnlockedThisDeviceOnly')) throw Error('Missing device-only Keychain storage');
console.log(`PASS: OpenStep project syntax, object references, scheme, ${sources.length} source memberships, iPad settings, permissions, DeepSeek endpoint and credential boundaries.`);
console.log('NOT CHECKED HERE: Swift type checking, Apple SDK compatibility, signing, physical-device speech recognition.');
