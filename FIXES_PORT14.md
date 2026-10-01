# port.14：修复启动辅助进程触发 launchd GUARD

实验版本与运行时：`3.0.10-roothide-port.14`，应用构建号 14。目标设备：iPhone XR / A12，iOS 18.3（22D60）。

## 真机证据

恢复图标后，用户反馈三款应用打开仍卡住。新报告 `panic-full-2026-10-01-141225.0002.ips` 记录：

- `launchd` 在 2026-10-01 21:12:25 UTC 因 `GUARD` reason 5 退出；加载的 libjailbreak/launchdhook UUID 与 port.12 运行时精确一致。
- RootHide 主进程 6811 在启动 check-in 中等待崩溃的 launchd 线程 148218；RootHide 辅助进程 6812 仍处于暂停状态。
- libjailbreak 偏移 `0x339b4` 调用 `thread_set_state(ARM_THREAD_STATE64)`，返回帧 `0x339b8` 位于 `proc_patch_dyld_internal +2876`。

调用链是：`systemwide_process_checkin → proc_ucred_update_content → target_proc_with_ucred → jb_credential_helper_start → credential_helper_patch → proc_patch_dyld_internal → thread_set_state`。

这与旧 boot 关机时的 SMR panic 不同，也不是图标缓存问题。可直接证明 RootHide 的等待与本次辅助进程异常有关；报告中没有 Sileo/Zebra 的运行线程，因此不能单凭这一份报告唯一归因三者的所有问题。

## 原因

RootHide 主程序具有 platform 权限，同一个可执行文件生成的辅助进程满足系统 hardened 判断。Apple XNU 对 hardened 目标的 PC/LR 修改要求调用者持有 `com.apple.private.thread-set-state`，否则向调用者发出致命 GUARD 5。旧 dyld 修改例程运行在具备这个权限的 jailbreakd；port.12 的新辅助流程在 launchd 中调用它，调用者权限前提不同。

`cs_allow_invalid`、`CS_GET_TASK_ALLOW` 和检查 `thread_set_state` 返回值都不能避免这项致命检查。

主来源：[Apple thread_act.c](https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.81.4/osfmk/kern/thread_act.c)、[task.c](https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.81.4/osfmk/kern/task.c)。公开 XNU 与设备内核有小版本差异；实际 GUARD 类型、二进制调用点和进程等待关系相互印证。

## 修复与验证边界

新版系统在辅助 dyld 入口交接时使用已存在的内存入口跳转方式，保留原来的系统线程寄存器及原 dyld 跳板，不再进入 `thread_set_state`。仍保留暂停启动、完成令牌、等待期限及失败清理；不修改所有应用的全局线程权限。

实际跳转只使用 x17 临时寄存器；完整 20 字节恢复执行权限，入口写入成功后才隐藏旧 dyld header。线程状态读取失败会释放已取得的 Mach 线程端口。

`scripts/test_dyld_entry.py` 测试实际生产函数：四种系统/PAC 组合、六步 VM 操作逐步失败、旧系统的线程修改/解映射失败，以及 ARM64 跳转指令的完整目标地址与参数寄存器保留。iOS 17+ 在任何 VM 失败情况下都不回退到 `thread_set_state`。

原桌面恢复和路径修复保留。已有 app 查询上下文问题并未因为本次线程保护修复自动得到验证。

本版本必须通过源码检查、真实 iOS SDK 编译、分支/跳转编码回归、完整 IPA 构建和最终二进制核验后才交付。macOS 测试不证明 iOS 私有 VM 操作兼容或三个 App 业务流程正常。安装 App 也不会自动替换已加载的旧运行时，必须另行验证实际激活与应用交互。
