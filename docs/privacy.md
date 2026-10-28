# Privacy and data flow

French speech is recognized on the iPad. Audio recordings stay local and are optional. Enabling Chinese captions sends French text, neighboring French context and the course glossary to the configured DeepSeek endpoint. Semantic review and explicit AI notes also send text to DeepSeek. This consumes the user's API balance.

The app connects to https://api.deepseek.com/chat/completions and does not use an OpenAI API endpoint. Users provide their own API key in the app; it is stored in the device-only Keychain. No API key, recording, course record, signing certificate or provisioning profile is included in this repository or the unsigned release.

Class data lives in the app's ClairLibrary directory. The historical Bundle Identifier/Keychain service/directory remain unchanged to support upgrades. An alternative signing team or container can have a different app data environment: export important classes before changing installation methods.

Do not attach classroom recordings, API keys or personal class exports to public issues.

## 数据与隐私

语音在iPad本机识别，可选录音留在本机。开启中文字幕、增强审查或AI整理会向DeepSeek发送相关法语文本、相邻前文及课程术语，消耗用户自己的API余额。密钥存入设备钥匙串，仓库和未签名IPA中不包含密钥、录音、课堂记录或签名证书。更换侧载/容器环境前先导出重要课堂；不要在公开Issue上传密钥或课堂录音。
