# TokenMonitor

macOS 菜单栏 Token 用量监控工具，支持 CBC 兼容中转站和知遥 API，并通过 `UsageProvider` 接口扩展其他站点。

本项目采用 [MIT License](LICENSE)。

macOS 14+ 菜单栏 Token 用量监控，支持 `cbc.icu` 和 `zyapi.tuluo.top:8888`。

## 当前能力

- 菜单栏可切换余额、余额与用量摘要、今日 Token、输入、输出、缓存命中率、请求数或费用
- 左键打开监控面板，右键可切换站点、刷新、打开设置或退出
- 概览显示可用/冻结余额、今日/累计请求、累计 Token、今日输入/输出/缓存/推理、今日/累计费用、响应时间
- 展示近 7 天 Token 趋势和今日模型用量
- 请求记录可展开查看请求 ID、密钥名称、端点、推理等级、分组、流式、首 Token 时间、耗时和错误
- 设置中可切换 CBC 与知遥 API；站点地址、会话和 API Key 按 Provider 独立保存
- API Key 和账号密码登录入口；凭据保存在应用目录的本地加密文件中，切换站点时自动恢复
- 刷新间隔和菜单栏显示内容保存在本机设置中
- 刷新失败时保留上一次成功数据

## 开发运行

在项目目录执行以下命令生成本机应用。默认放在 `~/Applications/TokenMonitor.app`，避免同步目录改写可执行权限：

```sh
zsh scripts/build-app.sh
open "$HOME/Applications/TokenMonitor.app"
```

首次运行后左键点击菜单栏图标，点击齿轮打开设置，选择站点并登录。CBC 默认地址是 `https://cbc.icu`，知遥 API 默认地址是 `https://zyapi.tuluo.top:8888`；直接粘贴 `/index` 或 `/dashboard` 页面地址也可以。真实凭据不要写入源码、README 或测试样例。

测试命令：

```sh
zsh scripts/check-fixtures.sh
zsh scripts/render-previews.sh
```

界面预览写入 `previews/`，使用脱敏固定数据，不访问站点或钥匙串。

## 打包安装

执行 `zsh scripts/package-app.sh`，安装镜像生成在 `dist/`。打开 DMG，将 `TokenMonitor.app` 拖到 `Applications`。当前构建为 Apple Silicon `arm64`，采用本机临时签名，尚未使用 Apple Developer ID 签名或公证。

这个检查会直接编译 Provider 和聚合逻辑，再用脱敏 fixture 验证概览、请求明细和失败请求过滤。真实 CBC 联调通过单独的本地进程环境完成，测试输出不会打印密钥。

## Provider 扩展

使用 CBC 同款接口的站点只需在设置中修改地址。接口不同的中转站需要实现 `UsageProvider`，将站点响应映射到 `UsageOverview`、`UsageBucket` 和 `UsageRecord`，然后在 `ProviderCatalog.all` 登记构造方式。凭据使用 Provider 标识独立保存，不会在切换站点时混用。

## 当前联调边界

`cbc.icu` 的 API Key 登录接口已按站点前端使用的 `/apikey/login` 实现。账号密码登录按 `/login` 提交空验证码字段；如果账号启用了验证码，需要增加验证码图片和输入控件。今日输入、输出和缓存指标来自使用记录分页聚合，累计 Token 和余额来自站点概览接口，两者统计周期不同。CBC 当前没有提供缓存写入字段，界面会标为“站点未提供”，不会误报为 0。

知遥 API 的账号密码模式可读取账户余额、累计 Token、请求明细和近 7 天费用趋势。API Key 模式使用站点为 CC Switch 提供的接口，只能读取共享余额和该 Key 的今日费用；该接口不返回 Token 明细，界面不会将缺失数据显示为 0。知遥 API 的输入、输出和缓存 Token 是分列字段，累计和今日 Token 总量会把缓存读写计入。请求刚建立但尚未完成时，接口可能返回空的输入输出和状态，界面会标记为“处理中”，不会计入成功用量。
