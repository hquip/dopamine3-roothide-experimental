# 第一版源码验证记录

这是源码、云端构建与编译期检查记录，不代表手机兼容性或越狱隐藏效果通过。

已完成：

- `python scripts/check_port.py`：冲突标记、plist/JSON、重复服务编号、实验版本标识、固定 RootHide bootstrap/Manager 内容检查通过。
- `python scripts/prepare_port.py`：指定 XPF 基础版本和补丁检查通过；在独立干净 checkout 上重新应用补丁，三个修改文件与工作区结果一致。
- `git diff --check 3.0.10`：整个移植相对上游的空白与冲突检查通过。统一补丁文件中的上下文空格按 `.gitattributes` 保留，其实际应用后的 XPF 源码单独通过 `git -C BaseBin/XPF diff --check HEAD`。
- GitHub 工作流 YAML、所有内联 shell 和 `scripts/setup_macos.sh` 的 Bash 语法检查通过。
- Application 的 Xcode OpenStep 项目可以解析，未发现重复对象 ID；DarkSword 保留上游 3.0.10 内容。
- XPF `src/common.c`、`src/xpf.c`：Windows Clang 21.1.8，`--target=arm64-apple-ios15.0 -fblocks -fsyntax-only`，使用真实 Theos iPhoneOS 16.5 SDK、ChOma 和项目头文件，通过且无诊断。
- `tests/protocol_abi.c`：同一编译器及 SDK，在 `arm64-apple-ios15.0`、`arm64e-apple-ios15.0` 上以 `-fblocks -std=gnu11 -fsyntax-only -Werror` 检查，通过且无诊断。

协议测试中的旧版期望值经过独立交叉核对：使用未修改的 RootHide tag 27 `jbserver.h` / `signatures.h` 及其固定 ChOma 头文件，而非从当前移植结构自我推导。两种架构下，真实 SDK 的 `fsignatures_t` 为 56 字节、`siginfo` 为 64 字节、旧 trust 请求为 120 字节。测试覆盖扩展签名字段，避免只按三个基础字段估算旧 ABI。

[第三轮 GitHub macOS 构建](https://github.com/hquip/dopamine3-roothide-experimental/actions/runs/36292486926) 已成功，源码提交为 `308ca31ac9fe4a03ecd98d12862e510ec79e1f89`。完整应用编译、链接、IPA 打包和 Xcode 设备 SDK 的 arm64/arm64e 协议检查全部通过，产物为 `experimental-roothide-port-3`。这次成功构建验证了此前修正的宿主 SDK、共享 bootstrap、CLI 及旧组件 SDK 问题。

这些检查没有执行手机内核写入、越狱程序或设备安装。相关 App/CLI 的 6 种 Objective-C 头文件配置，以及精简 CLI 的 4 个源文件也已完成真实 SDK 的交叉语法检查；实际工具版本、源码提交、IPA 校验值和构建日志随 Actions 产物保存。

设备上的 vnode/namecache 布局、远程 dyld/PAC、预编译依赖、重启与卸载，以及任何银行 App 的检测结果，仍需验证。详细清单见 [PORTING.md](PORTING.md)。
