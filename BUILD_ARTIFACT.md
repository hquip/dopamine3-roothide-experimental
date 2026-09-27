# 构建产物记录

## 修订版 port.2

[第四轮 GitHub Actions 构建](https://github.com/hquip/dopamine3-roothide-experimental/actions/runs/36301032194)
已通过完整编译、链接、IPA 打包和 iOS SDK 协议检查。

| 项目 | 值 |
| --- | --- |
| 构建源码提交 | `f89ab7f03b3e95bc3f493069d348d744f5e01f5d` |
| App 标识 | `com.opa334.Dopamine-roothide` |
| App 数字版本 / 构建号 | `3.0.10` / `2` |
| 实验版本 | `3.0.10-roothide-port.2` |
| IPA 大小 | 54,582,378 字节 |
| IPA SHA-256 | `1d3acead57252d55549bcdb237d60ac1fa219d4d9dd751b703f2977bebf67195` |
| 整个 Actions 附件 ZIP SHA-256 | `f47c65b9d605389f96959c163933bcd99e889505e055cdd1d10cd673c34a9451` |

已核对 GitHub 附件哈希、IPA 哈希与 CRC、来源提交、版本和资源。arm64、arm64e
中三个 crash reporter 入口均通过静态分支检查：iOS 17+ 路径提前返回，pause 返回 0。
App 根目录、basebin、momentarius、Titan 内四份 libjailbreak 的两架构 UUID 和代码哈希一致，
且相对第一版已更新。这里的分支检查不是在手机上执行越狱。

签名工具报告完成，随后通过设备安装记录确认构建号已为 2。尚未取得修订版成功激活、
重启恢复或隐藏检测通过的设备证据。修复原因及边界见 [DEVICE_VALIDATION.md](DEVICE_VALIDATION.md)。

## 第一版 port.1：已确认会崩溃，仅保留追溯记录

[成功的 GitHub Actions 构建](https://github.com/hquip/dopamine3-roothide-experimental/actions/runs/36292486926)，产物名为 `experimental-roothide-port-3`。

| 项目 | 值 |
| --- | --- |
| 构建源码提交 | `308ca31ac9fe4a03ecd98d12862e510ec79e1f89` |
| App 标识 | `com.opa334.Dopamine-roothide` |
| App 数字版本 | `3.0.10` |
| 实验版本 | `3.0.10-roothide-port.1` |
| IPA 大小 | 54,582,320 字节 |
| IPA SHA-256 | `d14ef4c2a36d53c94330abb9fe00ed36ac2b580a4d8f4a7e6df8ac7409e698e2` |
| 整个 Actions 附件 ZIP SHA-256 | `f3bbc0059c1e54ecf0782d4e75a2550b312039ba31ae534add1f3e8bcfb95c22` |

下载后已核对：GitHub 附件 ZIP 哈希、IPA 哈希、ZIP CRC、来源提交、Info.plist 版本、RootHide 标记、bootstrap 和 Manager 资源、basebin 中的 roothidehooks / jailbreakd / bootstrapper / libjailbreak，以及 V3 客户端符号。

IPA 本体与整个 Actions 附件 ZIP 的哈希不同，不能混用。对 IPA 重新签名后，IPA 哈希也会改变。

这份第一版产物后来已在目标 iPhone XR / iOS 18.3 上签名安装，但实际激活触发了 launchd GUARD 异常和整机重启，不能作为可用发行包。哈希保留用于追溯失败版本；已定位的问题与修订版范围见 [DEVICE_VALIDATION.md](DEVICE_VALIDATION.md)。重启恢复及银行 App 隐藏效果仍未验证。

## 修订版 port.3

提交 `9720b07d63c6d699ab8996b6dedd60af055363b1` 的[云端构建](https://github.com/hquip/dopamine3-roothide-experimental/actions/runs/36304375327)
已通过完整编译、iOS ABI 检查和真实 macOS libxpc 消息回归测试。IPA 已签名安装，设备记录确认
`CFBundleVersion=3`；安装后 Developer Mode 需要在手机上重新开启，尚未执行激活。
