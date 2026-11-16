# TokenMonitor 项目约定

## 版本交付

- 每个新版本都需要完成验证、提交代码并推送到 GitHub，不能只更新本机。
- 每个新版本都运行 `zsh scripts/package-app.sh`，生成对应版本号的 DMG，并上传到同版本的 GitHub Release。
- 版本号与构建号以 `Resources/Info.plist` 为准；发布前运行 `zsh scripts/check-fixtures.sh` 和 `git diff --check`。
- 保留现有远程提交，通过正常合并更新 GitHub 主分支；创建对应的 `v版本号` 标签，不强制推送或覆盖旧版本。
- 发布后核对远程提交、版本标签和 DMG 校验值，并安装、启动本机最新版本，确认实际运行版本号。
- 账号、密码、会话和 API Key 不得提交到仓库或写入发布说明。
