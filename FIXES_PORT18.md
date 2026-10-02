# port.18：处理静默的 LaunchServices 注册失败

port.17 在 `uicache -p` 返回错误时会回退到完整扫描，但部分 iOS 18.3 状态会出现退出码为 0、没有 stderr、LaunchServices 仍返回 `reported path: none` 的静默失败。

本版在 mobile 注册校验失败时也执行一次完整 `uicache -a`，随后重新读取 LaunchServices；只有第二次仍不匹配才返回错误。
