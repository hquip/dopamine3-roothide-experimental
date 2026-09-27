# RootHide 到 Dopamine 3 的移植记录

目标：iPhone XR / A12，iOS 18.3（22D60）。本记录描述实验源码，不能作为已经支持真机的声明。

## 固定来源与合并方式

| 项目 | 提交 |
| --- | --- |
| Dopamine 3.0.10 | `1a54e76d515ff5916b64e44d6afbb57d2bc89ee9` |
| RootHide 2.4.9.27 | `3824f2731275423c970ff6ed6685957dec269073` |
| 内容对比基础 Dopamine 2.4.9 | `36e4760e1f760c3223745132d8c90665002c550a` |
| 保留的 Dopamine 3 XPF | `9e12b8faa7444f6fe7f699aec6b6c96d151455d3` |
| RootHide XPF 增量来源 | `3fb4bb31a0900abfe6e8d88fc5b2df3b726b6722` |

由于历史中存在提交重写，本移植明确使用普通 2.4.9 的内容树作为差异基础，而不是声称它是两个分支的真实 Git 共同祖先。初始内容合并发现 35 条冲突记录，随后按子系统解决。

## 移植范围

- 保留 Dopamine 3 的新系统支持、ClearSword/momentarius 等组件、新版状态检测、提权回收和用户空间重启时序。
- 迁移 RootHide 双随机容器、bootstrap 路径映射、按 App 隐藏名单、进程启动分支和系统服务过滤。
- 保留 RootHide 服务编号 5，将本项目内的 Dopamine 专用服务改为编号 6，避免编号冲突。
- 保留旧的客户端函数包装层，将新代码调用移到 V3 接口；Mach 消息按旧版与 V3 magic 分别解析和回复，保留旧版签名来源枚举数值。
- 将运行时生成文件统一到 Dopamine 3 的 `/basebin/gen` 布局，并保留新版 dyld 产物分类。
- 手机 App 使用自身的越狱流程。上游 Standalone/Corellium 的 rootless 命令行安装器尚未移植；本分支 CLI 仅保留只读诊断，`install`/`activate` 会明确拒绝，不会创建全局 `/var/jb` 或挂载 fakelib。
- 旧 RootHide 系统插件使用已固定的 Theos 16.5 补丁 SDK 和仓库兼容头文件；Dopamine 3 原生组件继续使用所选 Xcode 的设备 SDK。
- 基于 Dopamine 3 的 XPF 增加 RootHide 的 namecache 与 AMFI OID 查找集合。补丁随主仓库保存，由脚本应用，避免引用尚未发布的自定义子模块提交。
- XPF 增量对查找失败返回错误，修复旧增量将失败地址记为 `-1` 的情况，避免跨内核映像缓存这两个查找地址，并补充新段资源的释放。
- 实验版本显示独立标识，禁止自动从旧 RootHide 或普通 Dopamine 发布渠道更新。
- 提供手动 GitHub Actions macOS 构建；保存源码/子模块提交、工具版本和构建日志。依赖源码与 SDK 固定，但 GitHub runner 和系统包仍可能更新，因此不宣称二进制逐位可复现。

## 必须区分的验证结果

| 检查 | 当前证据 |
| --- | --- |
| 来源与三方内容对比 | 已在 Windows 完成 |
| 冲突、plist/JSON、服务编号检查 | 使用 `scripts/check_port.py` 复核 |
| XPF 补丁与固定基线 | 使用 `scripts/prepare_port.py` 复核 |
| XPF 的两个补丁源文件 | Windows Clang 21.1.8 + 真实 iOS 16.5 SDK，arm64 交叉语法检查通过 |
| 新旧协议尺寸及函数签名 | 同一真实 SDK 下 arm64、arm64e 的 `tests/protocol_abi.c` 检查通过；不是完整 Xcode 构建 |
| macOS/Xcode 完整构建 | port.3 云端构建成功，源码提交 `9720b07`，运行编号 `36304375327`；macOS libxpc 回归测试通过 |
| IPA 生成及 Xcode 设备 SDK 协议检查 | 已通过，arm64、arm64e 均通过 `-Werror` 编译期检查 |
| IPA 签名与安装 | port.3 已签名安装，设备记录确认构建号为 3；安装后需重新开启开发者模式 |
| XR / iOS 18.3 越狱、重启、卸载 | 第一版触发 launchd GUARD，port.2 触发 jailbreakd 消息 `SIGABRT`；port.3 尚未激活，见 DEVICE_VALIDATION.md |
| 任意银行 App 的隐藏效果 | 尚未测试 |

## 仍需验证的关键问题

1. RootHide 原有 namecache/vnode、dyld 内部布局及系统私有 API 在 iOS 18.3 上是否仍适用。找到符号不等于确认布局。
2. RootHide bootstrap 和管理工具包含预编译组件，不能仅靠主仓库编译成功证明其接口和行为兼容；需要核对并实际测试。
3. 新旧客户端兼容适配需要双向测试，尤其是预编译调用方。使用宿主机占位基本类型做的协议尺寸检查，不能替代真实 iOS SDK 构建与运行测试。
4. 磁盘签名、进程内签名和临时分配签名的处理路径不同，不能把某一条路径的随机化推导成全部签名都隐藏。
5. App 主进程、扩展、预热、后台恢复、偏好查询、URL scheme 与服务访问需要分别验证；效果会随 App 版本变化。
6. 完成安装、升级、用户空间重启、完整重启、故障恢复及卸载验证后，才具备进一步评估目标 App 的基础。

初次设备验证应使用有可恢复备份的测试设备。当前源码及任何首次编译产物均应视作实验候选，而非已经通过兼容性验证的发行包。

具体检查证据和限制见 [VALIDATION.md](VALIDATION.md)。
