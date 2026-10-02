# port.19：等待异步 LaunchServices 注册

RootHide 的 lsd hook 会异步启动完整 `uicache -a`。port.18 虽然重试了完整扫描，但立即查询仍可能得到 `reported path: none`。本版在完整扫描后以 mobile 身份最多等待约 2 秒并重新查询 LaunchServices；权限错误或超时仍会返回明确失败。
