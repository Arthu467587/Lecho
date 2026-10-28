# Validation status

Version 1.3.0 / build 130.

- 32 Node business and source-wiring tests pass.
- 6 IPA-builder tests pass with controlled simulated macOS tools. The fixtures are not real executable IPAs.
- The project validator checks 17 Swift target members, project references, scheme, naming, permissions and the sole DeepSeek endpoint.
- The IPA was compiled on a contributor's Mac and its archive metadata was inspected. This does not demonstrate complete functional or long-duration classroom testing.
- Foundation/Speech/SwiftUI behavior, real streaming cancellation timing, long background capture, split-view interactions, translation quality and sideload-container compatibility still need independent device validation.

Run portable checks:

```sh
node --test Tests/*.test.mjs
node scripts/validate-project.mjs
python3 Tests/ipa_builder_test.py
```

The Python fixtures use Bash. On Windows, set LECHO_TEST_BASH to the installed Git Bash executable if bash is not on PATH.

Run native checks on a compatible Mac with Xcode:

```sh
bash scripts/check-mac.sh
```

The native script executes the Foundation assertions and builds an unsigned iPad target. It is not a substitute for classroom testing.

## 中文检查说明

32项Node业务/接线检查、6项模拟打包流程检查及17个Swift工程成员/引用检查通过。IPA已在贡献者Mac编译，并核对了归档与真机二进制元数据；这不等于完整课堂、后台、分屏、SSE取消或翻译质量已验收。

可运行上方命令复现便携检查；模拟打包测试中的macOS工具和程序为桩，测试ZIP不是可安装IPA。真实语音和UI行为仍应在兼容的Mac/iPad上验证。
