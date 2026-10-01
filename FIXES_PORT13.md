# port.13 应用恢复修订

应用版本 `3.0.10-roothide-port.13`，构建号 13。兼容的运行时仍是 `3.0.10-roothide-port.12`；BaseBin 源码和协议未改。已激活 port.12 的设备可更新应用后使用恢复功能，无需为此重新激活越狱。

## 已确认的问题

内置 RootHide uicache 2.1.6-4 对 `-p` 参数执行 `jbroot(path)`。旧恢复代码却传入了已经包含 jbroot 的绝对路径，导致根目录重复拼接。工具在这种情况下输出 `Error: Unable to parse app ...`，但仍返回 0；旧代码只保留非零退出的 stderr，随后可能用已有 LSApplicationProxy 错误认定本次注册成功。

匹配的固定工具源码：[uicache](https://github.com/roothide/uikittools-ng/blob/f2c0e7aa11fadde365abd3d3e312b47bba23f332/uicache.m)。上述 `jbroot` 调用与内置二进制也已对应，不仅依据最新分支推断。

## 修复

- 注册参数使用虚拟 `/Applications/Sileo.app`、`/Applications/Zebra.app`、`/Applications/RootHide.app`；物理路径仅用于文件与注册结果核验。
- 即使命令返回 0，也保存并记录 stderr；识别工具的 `Error:` 输出，在查询旧记录前报告失败。
- 在 root 下解析预期物理路径，恢复权限后以 mobile UID 501 查询 LaunchServices，避免用 root 上下文替代桌面用户的观察。
- 注册路径的 `/var` 与 `/private/var` 比较使用字符串规范化，mobile 核验无需临时提权读取文件系统。
- 单独标记应用版本与要求的运行时版本，保持已激活的 port.12 兼容。

## 验证与边界

`tests/app_registration.m` 使用真实生产帮助函数验证虚拟路径、拒绝重复根路径/非法应用名、返回 0 的工具错误、正常诊断、路径别名和 App/运行时版本区分。工作流在 macOS 上运行 Foundation 测试，然后编译、链接、打包并验证原有协议。

首次真实设备测试确认应用构建号 12，用户反馈三款应用仍未显示。旧 boot 的关机 SMR 崩溃与 09/28 报告一致，不能据此认定是 port.12 新激活失败。

本修订修正确定的参数与错误传播缺陷；是否恢复桌面图标和三个 App 的正常响应仍需要设备验证。系统应用登记、包文件存在和桌面可见性应分别判断。
