# 首次设备失败与 crash reporter 兼容性修复

目标设备为 iPhone XR（A12），iOS 18.3 / 22D60。第一版 IPA 来源提交为
`308ca31ac9fe4a03ecd98d12862e510ec79e1f89`，实验标识为
`3.0.10-roothide-port.1`。签名安装及开发者模式检查成功；实际激活失败，
表现为出现 Apple 标志并整机重启。port.2 修复该问题后，第二次测试又触发了
`launchd` 的 `SIGABRT`。当前修订版标识为 `3.0.10-roothide-port.3`。

## 证据

通过既有配对会话只读复制的三份近期系统报告均记录：

```text
initproc exited -- exit reason namespace 23 subcode 0x2000000600000000
Panicked task: pid 1: launchd
```

依据 Apple XNU 的 `bsd/sys/reason.h` 与 `osfmk/mach/port.h`，这是
`OS_REASON_GUARD`、Mach port guard 类型和
`kGUARD_EXC_EXCEPTION_BEHAVIOR_ENFORCE`。它不是缺少独立 PAC 绕过选项的证据。

三份报告的同一调用链都匹配原始 IPA 的 arm64e 镜像 UUID。符号表和返回地址前的
调用指令交叉核对得到：

| 镜像 | UUID | 镜像内返回地址 | 所在函数及刚刚调用的函数 |
| --- | --- | --- | --- |
| libjailbreak.dylib | 23a2f402-f6b7-3ef7-ba5f-996efb8d4f13 | 0x2f158 | crashreporter_resume → task_set_exception_ports |
| libjailbreak.dylib | 同上 | 0x2fe28 | crashreporter_start → crashreporter_resume |
| launchdhook.dylib | 2855fe47-9e7c-30ab-bca9-f545d0ed07d4 | 0x4918 | initializer → crashreporter_start |

镜像未包含 DWARF，因此源代码行号由调用目标、参数及固定源码交叉核对，
不是声称拿到了 DWARF 行号映射。原始设备报告及个人设备标识不放入仓库。

## 修复范围

上游 Dopamine 3.0.10 的 `BaseBin/launchdhook/src/crashreporter.m` 已在
`start`、`pause`、`resume` 三个入口跳过 iOS 17 及以上系统。RootHide 移植禁用了
该文件，改用 `libjailbreak/src/roothider/crashreporter.m`，后者遗漏了这个系统版本限制。

修订版在实际使用的三个入口恢复同一限制；iOS 17 及以上保留系统原生崩溃处理，
不安装或改写可选的旧 Mach 异常处理器。早期系统的旧实现与 pause/resume 配对接口保留。
此修改不关闭系统 GUARD 保护，也不改变漏洞选择或包管理器选择。

## 验证边界

port.2 的新报告定位到 `roothider/jailbreakd.c` 的显式 `abort()`：私有
bootstrap 端口收到消息后，代码假设全局 XPC hook 已经消费它。RootHide 2 的
hook 是函数入口拦截；当前移植使用导入符号重绑定，不能保证覆盖 libxpc 内部路径。
port.3 增加了显式的 typed callback，让该端口调用原有 jbserver dispatcher，保留
审计令牌、RootHide 过滤、domain/action 和权限检查；拒绝消息返回明确的非零错误，
不伪造成功，也不再让合法消息触发 `abort()`。

修订源码已通过现有 `scripts/check_port.py` 和 `git diff --check`；修改过的
Objective-C 文件使用 Windows Clang 21.1.8 与真实 iPhoneOS 16.5 SDK，分别对
arm64、arm64e 完成交叉语法检查，两次均无诊断。另行复核了 pause 返回值的唯一
业务调用方，它只将 key 原样传给 resume；保留函数签名且新系统两端均不改状态。

本记录确认第一版的重复崩溃位置。修订版的源码检查、完整构建和设备复测结果应分别记录；
修复一个已证实的启动崩溃不等于其余 RootHide 组件、重启恢复、卸载或银行 App 隐藏已通过。
不要对第一版反复进行相同激活尝试。

修订版 port.2 的[云端构建](https://github.com/hquip/dopamine3-roothide-experimental/actions/runs/36301032194)
已通过；其产物的两架构、三个入口版本分支已在内存中静态核对，四份内置 libjailbreak
副本的 UUID/代码一致且已更新。设备安装记录确认构建号 2，但它仍在第二次激活时
触发了上述 `SIGABRT`。port.3 的完整构建、消息回归测试和设备验证尚待完成。
修订版源码提交、哈希及检查范围见 [BUILD_ARTIFACT.md](BUILD_ARTIFACT.md)。
