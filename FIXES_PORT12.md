# port.12：凭据辅助进程与应用恢复修复

目标设备：iPhone XR / A12，iOS 18.3（22D60）。实验版本：`3.0.10-roothide-port.12`，应用构建号：12。

## 修复的问题

RootHide、Sileo、Zebra 启动卡住的历史 watchdog 报告显示，RootHide 等待 check-in，launchd 同时未完成 iOS 17+ 的凭据辅助流程。移植保留了 Dopamine 3 对 patched dyld 的握手依赖，却允许 RootHide 默认关闭 dyld 补丁，内部 helper 没有独立适配。

- 保留同一可执行文件生成合法凭据的设计，以暂停状态创建内部 helper；直接为该 helper 加载 patched dyld，成功后才恢复，不依赖全局 dyld 开关。
- 父进程先关闭管道写端，检查单字节 `0x42` 完成信号，握手最多等待 3 秒。错误、EOF、超时、补丁失败都会清理子进程；不会执行目标 App 或递归等待 launchd check-in。
- 凭据设置调用失败不再发送成功信号；服务端传播失败，成功后才更新保存的 UID/GID 和审计令牌。修正 setgid 时主组传递。
- 缺失/损坏的 loader 和无法确认的 task 布局返回错误，避免用断言或 abort 终止 launchd。loader 缓存只发布完整结果，失败可以重试。

恢复流程以前丢弃安装、提权和注册失败，可能错误显示“恢复成功”。本版本修正结果处理：

- 真实 UID 非 root 的安装保留 helper 的实际退出结果。命令仍在 Dopamine 恢复临时权限后执行；保留上游 helper 在等待前取得永久 root 的顺序，验证父进程完成信号并移除内部控制参数。
- 校验有效 jbroot、工具和 dpkg 数据库；每个包必须是 `install ok installed`，目标 App 的 Info.plist、bundle ID 和主程序必须完整。
- 逐项调用 uicache 注册，再核对 LaunchServices 指向当前实际路径。恢复流程不再隐式重建整个应用数据库。
- 提权和沙盒权限操作使用进程级互斥，获取、执行和恢复错误都有结果；恢复操作阻止重复启动。界面显示执行状态和具体失败阶段。
- 恢复命令等待最多 120 秒，解析退出与信号状态，读取最多 8 KiB stderr 用于错误反馈；失败清理不会再无限等待子进程。
- rootPath 查询失败不再永久缓存，空路径或错误类型不会被当作可用 Bootstrap。
- 恢复前核对活动 basebin 与 App 的实验版本，旧运行时会显示完整重启并通过新版重新激活的提示。

其他失败处理包括：persona 仅在 spawn 成功且 PID 有效时执行，检查修复结果、恢复调用方的 spawn 参数；内部启动补丁失败清理挂起进程；已有超时 child-patch 请求增加进程唯一 ID，防止迟到请求作用于复用的 PID。

## 验证

GitHub Actions 工作流在完整 IPA 构建前执行：

1. `credential_helper_regression.c`：使用真实 macOS 暂停 spawn 和管道测试正常握手、错误令牌、EOF、超时、补丁失败、启动失败、fd 3 冲突及子进程清理。
2. `jbctl_parent_wait_regression.c`：验证父进程令牌、延迟完成、EOF、错误令牌、超时、非法参数和内部参数剥离。
3. `test_runtime_safety.py`：以实际生产函数测试 rootPath 查询重试、损坏回复、并发发布、嵌套请求、persona 失败和子进程身份检查；macOS 还测试实际子进程清理。
4. `dpkg_status.m`：使用实际 Foundation 解析器测试完整安装、删除/解包状态、包名前缀混淆、续行及 CRLF。

随后执行完整应用编译、链接、IPA 打包、真实 iOS SDK 的 arm64/arm64e 协议检查，以及既有 libxpc 分发回归。

Windows 已通过相关源码的真实 iOS 16.5 SDK 语法检查及可在本机执行的运行时失败测试。原生 macOS 生命周期测试、完整构建和最终产物应以对应 Actions 运行日志为准；日志随 IPA 保存。这些验证不执行 iOS 内核漏洞利用。

## 尚未证明的事项

- port.12 尚未证明在目标设备上完成稳定激活和三个 App 的完整使用流程。更新 Dopamine App 也不会自动替换已经加载的旧运行时。
- 私有内核/dyld 操作需要真机验证；历史堆栈只定位到凭据 helper 阶段，不能单凭它区分当时卡在 spawn 还是管道读取。
- 旧 exec START/CANCEL 协议保持原有同步语义。直接增加客户端超时会留下迟到操作并破坏 exec 状态，后续需要服务端取消或期限协议，不能宣称所有等待路径都已有超时。
- 进程唯一 ID 检查缩小了 PID 复用风险，但不构成内核进程生命周期的原子锁。
- 任意银行 App 的越狱隐藏效果仍未测试。

本修复不改变漏洞利用选择、不强制开启所有进程的 dyld 补丁、不修改越狱隐藏名单。
