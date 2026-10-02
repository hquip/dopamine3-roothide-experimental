# port.17：回退到完整 uicache 注册

port.16 已修复默认软件源，但 Sileo 在目标路径注册阶段仍可能报告 `reported path: none`。RootHide 的虚拟 `uicache -p` 路径在部分 iOS 18.3 状态下会失败，而完整 `uicache -a` 可以重新扫描并注册 jbroot 应用。

本版在目标注册失败时只执行一次完整扫描，然后继续逐项验证 Sileo、Zebra 和 RootHide Manager 的 mobile LaunchServices 路径。完整扫描失败或验证仍不匹配时仍返回明确错误，不会显示假成功。
