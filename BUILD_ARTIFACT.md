# 已验证的构建产物

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
