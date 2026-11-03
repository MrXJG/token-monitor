# TokenMonitor

macOS 菜单栏 Token 用量监控工具，支持 CBC、CBC 旧版和知遥 API，并通过 `UsageProvider` 接口扩展其他站点。

本项目采用 [MIT License](LICENSE)。

macOS 14+ 菜单栏 Token 用量监控，支持 CBC 当前站点 `runok.ai`、`cbc.icu` 旧版接口和知遥 API。

## 当前能力

- 菜单栏可切换余额、余额与用量摘要、今日 Token、输入、输出、缓存命中率、请求数或费用
- 左键打开监控面板，右键可切换站点、刷新、打开设置或退出
- 概览显示可用/冻结余额、今日/累计请求、累计 Token、今日输入/输出/缓存/推理、今日/累计费用、响应时间
- 展示近 7 天 Token/费用趋势，悬停查看每日明细、点击固定、左右方向键切换日期；保留数值刻度和今日模型用量
- 请求记录支持状态、模型、时间筛选和最新/费用排序；筛选范围为已加载记录，可分页加载历史；点击单条进入详情，可复制请求 ID 和错误信息
- 设置中可切换 CBC、CBC 旧版与知遥 API；站点地址、会话和 API Key 按 Provider 独立保存
- 支持隐藏或恢复内置站点和自定义站点；隐藏只从切换列表移除，配置、凭据、别名和倍率记录继续保留
- CBC 使用账号密码登录；CBC 旧版保留 API Key 和账号密码入口。凭据保存在应用目录的本地加密文件中，切换站点时自动恢复
- 自动刷新可选 10 秒、30 秒、60 秒、5 分钟或自定义整数秒数，最短 5 秒，建议不少于 15 秒；刷新间隔和菜单栏显示内容保存在本机设置中
- 面板打开时使用所设刷新间隔；面板关闭后至少 60 秒，低电量模式后台至少 5 分钟。睡眠时暂停，唤醒后补刷；打开面板时补齐过期数据
- 七日趋势和分组倍率每 5 分钟更新，手动刷新会立即重新读取。今日统计、列表及 CBC 趋势回退共用本轮分页结果，常规刷新保留已加载的历史窗口
- 接口限流时按服务器等待时间或逐步退避暂停刷新，保留上次成功数据
- 概览、请求记录、趋势分别处理成功和失败，失败部分保留旧数据；顶部显示当前标签上次成功更新时间和下次刷新倒计时
- 设置按连接、刷新、菜单栏分组；自定义服务地址折叠收纳并校验格式
- 请求记录较少时面板缩短，详情和数据较多时可滚动；顶部标签和操作固定
- CBC 新版在站点名称旁显示最近请求的分组及最新倍率，点击查看全部可用分组。账户专属倍率优先于分组默认倍率；高峰配置单独标注，标题显示基础倍率
- CBC 旧版按 `statusCode`、`fail` 和兼容的 `status` 字段判断请求状态；旧接口没有 `status` 但返回 `statusCode: 200` 或 `fail: "0"` 的成功记录会正确显示为成功。旧版记录还显示接口提供的分组和请求倍率
- 分组倍率每 5 分钟检查，变化时保留旧值、新值和发现时间，并尝试发送系统通知；在“设置 → 刷新”中可关闭通知。首次读取建立基准，按站点及账号分别保存，重启后仍保留最近 20 条变化

## 开发运行

在项目目录执行以下命令生成本机应用。默认放在 `~/Applications/TokenMonitor.app`，避免同步目录改写可执行权限：

```sh
zsh scripts/build-app.sh
open "$HOME/Applications/TokenMonitor.app"
```

首次运行后左键点击菜单栏图标，点击齿轮打开设置，选择站点并登录。CBC 默认地址是 `https://runok.ai`，使用 `/prod-api` 接口；CBC 旧版保留 `https://cbc.icu` 的配置和接口；知遥 API 默认地址是 `https://zhiyaoapi.top`，旧地址 `https://zyapi.tuluo.top:8888` 已停用。站点别名可在连接设置中修改，显示在概览标题和菜单栏提示中。真实凭据不要写入源码、README 或测试样例。

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

Provider 若需从请求记录汇总趋势，可实现带有 fetchPage 参数的 fetchTrend，使用调用方传入的分页读取函数，以便与今日统计、列表共享请求。默认实现转调原有 fetchTrend，已有 Provider 无需修改。

支持当前分组倍率的 Provider 可声明 `.groupRates` 并实现 `fetchGroupRates`，将账户标识映射到 `UsageOverview.billingAccountID`，请求分组标识映射到 `UsageRecord.groupID`。默认实现不请求倍率接口，已有站点可继续使用。CBC 网关旧配置读取 `/api/v1/groups/available` 和 `/api/v1/groups/rates`；CBC 读取 `/aigate/group/available` 监控全部启用分组的倍率；知遥读取 `/public/groups` 的渠道倍率，并在请求记录明确返回渠道 ID 或倍率时显示当前使用倍率。标题只展示最近请求实际使用的分组和倍率。

倍率提醒只能比较应用实际读取过的值，无法补报首次安装前发生的变化。应用运行且登录有效时才检查；系统通知需要 macOS 授权，未授权或关闭通知时，变化仍保留在面板内。高峰时段附加倍率、模型单价及其他计费规则不计入基础倍率变化提醒。

## 当前联调边界

CBC 的账号密码登录使用 `/login`，CBC 旧版的 API Key 登录仍使用 `/apikey/login`；两套配置和本地会话按 Provider 独立保存。旧版日志使用 `statusCode`、`fail`、`status` 的优先级兼容判定，记录没有日志 ID 时使用请求字段生成稳定 ID，避免自动刷新后重复记录。CBC 新版使用 `/api/v1/auth/login`、`/api/v1/auth/refresh` 和 `/api/v1/usage`，可读取余额、请求、Token、缓存读写及趋势。新版访问令牌和刷新令牌按独立 Provider 保存在本地加密文件中。今日输入、输出和缓存指标来自使用记录分页聚合，累计 Token 和余额来自站点概览接口，两者统计周期不同。

知遥 API 的账号密码模式可读取账户余额、累计 Token、请求明细和近 7 天费用趋势。API Key 模式使用站点为 CC Switch 提供的接口，只能读取共享余额和该 Key 的今日费用；该接口不返回 Token 明细，界面不会将缺失数据显示为 0。知遥 API 的输入、输出和缓存 Token 是分列字段，累计和今日 Token 总量会把缓存读写计入。请求刚建立但尚未完成时，接口可能返回空的输入输出和状态，界面会标记为“处理中”，不会计入成功用量。
