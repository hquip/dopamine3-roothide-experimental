# port.15：避免 launchd 等待挂起的 jailbreakd

port.14 的两份真机报告都记录了 `watchdogd` 超时。launchd 的 eventq 线程停在 `jbdSpawnPatchChild → jailbreakdXpcRequestWithTimeout`，而快照中的 jailbreakd 主线程仍是 suspended，导致 launchd 的工作线程逐渐耗尽。

本版的运行时改动：

- iOS 17 及以上，launchd 的 spawn posthook 在子进程保持暂停时直接调用现有 `roothide_patch_proc`，完成身份复核后再恢复子进程；不再从 launchd 同步发送 jailbreakd XPC 请求。
- jailbreakd 自身不再被送入这条补丁路径，避免“服务尚未启动却等待服务响应”的循环。
- `RESPAWN_REQUIRED` 只在启用 dyld 补丁时执行自重启；替换进程补丁失败时立即杀死并回收，避免留下永久 suspended 的服务进程。
- Dopamine 只在 RootHide loader、Bootstrap 和清理全部完成后才发布“已越狱”状态；失败流程会清除进程内状态。

这版仍需在 XR / iOS 18.3 真机验证。源码和 macOS 回归测试不能证明私有 VM 操作一定成功；如果设备再次出现 watchdog panic，应停止重试并保留新的 panic 报告。
