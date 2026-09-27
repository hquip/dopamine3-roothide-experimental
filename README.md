# Dopamine 3 + RootHide：实验移植

本分支以 Dopamine **3.0.10** 为基础，移植 RootHide **2.4.9.27** 的目录隔离、按 App 隐藏和系统服务适配代码。目标测试设备为 **iPhone XR / A12 / iOS 18.3 / 22D60**。

**这是实验移植，已通过 macOS 完整编译和设备 SDK 的协议检查，尚未经过目标手机验证。不是官方 RootHide 3 发布版，也没有证明可以通过任何银行 App 的检测。** 已知验证缺口见 [PORTING.md](PORTING.md)。

[已成功的构建与 IPA 附件](https://github.com/hquip/dopamine3-roothide-experimental/actions/runs/36292486926)，对应源码提交 `308ca31ac9fe4a03ecd98d12862e510ec79e1f89`。

## 在 Windows 上使用 GitHub 构建

1. 将此分支的全部源码提交到自己的 GitHub 仓库，保留 `.github`、`.gitmodules`、`patches`、`scripts` 和内置资源。
2. 在 GitHub 仓库的 **Actions** 页面选择 **Build experimental Dopamine 3 RootHide port**。
3. 点击 **Run workflow**，选择包含本次修改的分支。
4. 工作流在 `macos-15` 上准备 Xcode 构建依赖、应用固定的 XPF 补丁并运行构建。
5. 成功时下载 `experimental-roothide-port-<运行编号>`，其中包含 `Dopamine.ipa`、构建日志和 SHA-256。失败时查看步骤日志以及日志附件，继续修正编译错误。

首次手动触发前，工作流文件通常需要先存在于仓库默认分支。构建过程不需要连接 iPhone，也不需要先越狱。IPA 生成后仍需适合该设备的签名安装流程，然后才进入手机上的越狱及隐藏效果测试。

工作流构建当前仓库检出的代码，不会重新克隆旧 RootHide 项目替代它。它只上传 Actions 构建附件，不发布 Release。GitHub 的构建额度和收费以账户及仓库类型为准。

## 本地检查

从 Git 克隆该项目后：

```text
git submodule update --init --recursive
python scripts/check_port.py
python scripts/prepare_port.py
```

Windows 可以运行上述源码检查。完整编译使用 macOS/Xcode；构建所需的依赖固定值记录在 `.ci/dependencies.json`，子模块版本记录在 Git 中。`prepare_port.py` 将补丁应用到指定的 XPF 提交，可重复执行。

macOS 上可参考 GitHub 工作流安装 Procursus 打包工具，再执行：

```sh
bash scripts/setup_macos.sh
export THEOS="$PWD/.port-build/theos"
gmake BUILD_STANDALONE=0
```

源码检查通过只表示未发现特定的合并或配置错误；编译通过也不等于真机兼容和隐藏效果通过。

## 来源

- [Dopamine](https://github.com/opa334/Dopamine)
- [Dopamine2-roothide](https://github.com/roothide/Dopamine2-roothide)
- [RootHide 开发文档](https://github.com/roothide/Developer)

保留上游许可证与署名，详见 `LICENSE.md`。本分支与上游项目的正式发行渠道无关。
