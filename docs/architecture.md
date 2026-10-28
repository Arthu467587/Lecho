# Architecture

L'écho is a native SwiftUI iPad application, not a wrapper around the macOS Clair executable.

- LocalSpeechCapture converts microphone/imported audio and feeds Apple's on-device French SpeechTranscriber/SpeechAnalyzer.
- TranscriptLedger replaces revised audio ranges without blindly appending duplicate ASR text.
- SemanticSegmentation first exposes comma/short clauses; FirstPassCaptions records initial complete Chinese and preserves provisional coverage across merge, split and resume.
- DeepSeekTranslation manages streamed captions, source revisions, bounded concurrency, semantic review preemption and generation checks.
- ClassDocument/ClassLibrary persist raw lines, semantic units, captions, notes, bookmarks and audio parts. Original speech remains available after correction.
- ClassContinuation preserves class identity, accepted-frame offsets and separate microphone recording files.
- LechoApp/ClassReviewView provide the paper/forest classroom UI, swipe actions, persistent fonts and optional ambiguity hints.

Pure semantic repairs use at most one live request slot. Initial captions and real ASR corrections have primary priority. Speech timing and server/network time still determine observed latency. A 120ms closed-clause debounce is not an end-to-end latency promise.

Apple audio interruptions and force-quit can stop capture. Imported audio pauses in background; classroom microphone capture uses actual background audio, not silent playback.

## 架构说明

原生SwiftUI界面；LocalSpeechCapture负责本机法语识别，TranscriptLedger处理识别修订，SemanticSegmentation与FirstPassCaptions负责逗号首译及合并暂译保留。DeepSeekTranslation管理流式中文、请求优先级和过时回调。ClassDocument/ClassLibrary保存原文、字幕、笔记、重点和录音映射，ClassContinuation维持同一课堂的接续时间。首译与真实识别修正优先，纯合并补译最多占一个实时请求槽。
