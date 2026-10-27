# L'écho · 法语课堂即时中文字幕

[English](README.md) · [下载 IPA](https://github.com/Arthu467587/Lecho/releases)

基于[Clair](https://github.com/steinyanaa/Clair)的原生iPad课堂应用。本地识别法语，使用你自己的DeepSeek API生成中文字幕，支持数学、物理课程术语；界面为墨绿与米黄纸面风格。

## 功能

- 逗号先暂译，长句按短片段兜底，后续再审查/合并；修订期间保留已显示中文。
- 暂停、保存退出、同课续听，保留笔记/重点/时间轴；可选录音分段保存，不覆盖旧录音。
- 真实麦克风后台听课、字幕字号持久保存、法中/法语/中文切换、小型歧义提示。
- 课堂搜索、左右滑动移到最近删除、恢复及确认永久删除。
- 导入音频、回听、课后修改原文并定向补译、AI整理、Markdown/SRT/JSON与录音导出。

## 安装与使用

需支持本地法语语音识别的真实iPad，最低iPadOS26。中文翻译需要网络和你自己的DeepSeek API密钥，按服务商规则计费；没有OpenAI API接口。

从[Releases](https://github.com/Arthu467587/Lecho/releases)下载Lecho-1.3.0-unsigned.ipa，交给兼容的重签/侧载或容器工具处理。该包未签名，不附带证书；具体工具的兼容性与续签由工具本身决定。安装后在设置中输入自己的密钥和课程术语。

## 从源码生成IPA

在安装完整且兼容的Xcode的Mac上：

```bash
git clone https://github.com/Arthu467587/Lecho.git
cd Lecho
bash scripts/build-sideload-ipa.sh
```

成功后会在Finder选中work/Sideload-时间编号/Lecho-1.3.0-unsigned.ipa。该步骤不要求购买开发者会员或连接iPad。若已有脚本编译好的.app，可执行：

```bash
bash scripts/build-sideload-ipa.sh --reuse-latest
```

也可打开L'écho.xcodeproj，选择L'écho Scheme，按Xcode流程签名安装。升级旧应用时沿用原来的实际Team/Bundle Identifier，并先导出重要课堂。

## 测试与数据

[检查记录](docs/validation.md)：32项Node业务/接线检查及6项模拟打包流程检查通过；v1.3.0 IPA已在Mac编译，完整真机交互、后台、翻译质量仍需进一步验证。短片段可能增加API调用次数，无法保证固定字幕时延或准确率。

语音识别与可选录音留在本机；启用翻译/增强审查/AI整理会发送相关法语文本、上下文和术语给DeepSeek。密钥存入本机钥匙串。见[数据说明](docs/privacy.md)。不要在公开Issue中上传密钥或课堂录音。

## 许可与署名

采用MIT许可，保留Clair作者steinyanaa的上游署名及许可证。见[LICENSE](LICENSE)、[LICENSE-Clair.txt](LICENSE-Clair.txt)与[NOTICE](NOTICE)。
