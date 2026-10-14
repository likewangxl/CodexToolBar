# 安装、升级与卸载

## 源码安装

1. 安装 Xcode 命令行工具（`xcode-select --install`），确认 `swift --version` 为 5.9 或更高。
2. 打开并登录 Codex 桌面应用，正常打开一个本机任务。
3. 克隆 `https://github.com/likewangxl/CodexToolBar.git` 并进入 `CodexToolBar` 目录。在项目目录运行 `swift test`，再运行 `./scripts/install.sh`。
4. 工具安装到 `~/Applications/CodexTouchBar.app`，通过菜单栏控制。登录启动可自行开启。

账户 CLI 从 `/Applications/Codex.app`、`/Applications/ChatGPT.app` 或用户 `~/Applications` 的对应应用中发现。自定义 `--codex-home` 用于开发测试，不会新建登录；共享账户登录须由 Codex 本身管理。

发布包只带当前构建架构。主要目标是 Intel Touch Bar Mac，请使用 Intel 构建或核对 `file CodexTouchBar.app/Contents/MacOS/CodexTouchBar`。macOS 13 是最低声明版本，具体组合以实机兼容记录为准，不承诺所有版本均已测试。

本地构建默认使用 ad-hoc 签名，没有开发者公证。若分享二进制，维护者应另行完成 Developer ID 签名和公证；本项目不会要求关闭 Gatekeeper 或系统完整性保护。

## 权限与语音

仅首次点击麦克风才请求权限。到系统设置 → 隐私与安全性，分别允许“麦克风”和“语音识别”。若重新签名后权限异常，先关闭并重新打开工具检查系统提示，不要默认重置其他应用权限。

复核页显示接收任务；点“编辑”纠正文字，保存后回到复核，点击发送才提交。Esc 或关闭编辑窗口放弃本次修改，保留先前草稿。锁屏/睡眠自动关麦；未保存的编辑内容不持久化。

## 升级

升级前在工具菜单选择退出，再执行安装脚本。新包通过签名校验后替换旧版，不保留旧应用或归档，并清除安装用的 dist 应用副本，避免系统搜索出现重复应用。需要旧版时可从对应 Git 提交重新构建。

## 卸载

1. 在工具右键菜单关闭“登录时启动”，然后退出工具。
2. 运行 `python3 scripts/uninstall.py` 查看计划；确认后运行 `python3 scripts/uninstall.py --apply`。
3. 脚本只将本工具移到废纸篓，拒绝符号链接或包标识不匹配的路径，不删除 Codex 数据。

旧应用备份、偏好设置和缓存默认保留。需要完全清理时，可在确认没有要保留的验收记录后，手动删除 `~/Library/Caches/local.codex.touchbar`，并运行 `defaults delete local.codex.touchbar` 清除本工具偏好。不要删除 `~/.codex`，其中是 Codex 的任务和登录数据。
