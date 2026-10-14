# TokenBar · by Robby

A native macOS menu-bar app for monitoring your AI agent quotas across accounts. Local credentials stay on your Mac; each provider is connected explicitly.

TokenBar 把多个 AI Agent 账号的额度放到 macOS 菜单栏和桌面小组件。点击数值即可查看剩余比例、重置时间和数据更新时间；应用没有 Dock 图标，也不需要常驻主窗口。

[下载安装包](https://github.com/robbywang25/tokenbar/releases) · [问题反馈](https://github.com/robbywang25/tokenbar/issues) · [MIT 许可证](LICENSE)

这是围绕个人审美与工作流制作的独立实现：紧凑的账号列表，明确的数据时效，以及接入已有额度后台的本地、HTTPS 和 SSH JSON 来源。菜单栏额度工具已有成熟选择，例如 [CodexBar](https://github.com/steipete/CodexBar) 和 [QuotaBar](https://github.com/QuotaBar/QuotaBar)；本项目没有将这些通用能力宣称为独创。它也与 [Arnie016/TokenBar](https://github.com/Arnie016/TokenBar) 这一同名项目无关联。

0.2.4 小组件版提供 Developer ID 签名并通过 Apple 公证的 Universal DMG、ZIP 和 SHA-256 校验文件，包含 Apple silicon 与 Intel 架构。默认源码构建仍是本机 ad-hoc 菜单栏版，不能代替已验收的分发包。详见 [发布说明](RELEASE.md)。

## 能看到什么

- 以邮箱为主标题展示 Codex、Claude Code、Grok Build 和自定义数据源，套餐、服务和状态保持次要层级。设置、悬停提示和临期提醒同样使用邮箱。
- 来源暂时不可用时可保留同一来源上次识别的邮箱，悬停会注明；没有可信邮箱时显示“邮箱待确认”。来源变更或已识别账号变更会清除旧身份标签，旧余额不会因此变成实时。
- 同步新版 Tokens 的套餐名称、限流/待更新原因、逐来源采集时效与 requests 单位。Reserve 继续隐藏，不参与可见额度时效和提醒。
- Codex 套餐按已确认的倍率显示，例如 `Pro 25x`、`Pro 20x`；保留来源原始套餐名，不用月费推算倍率，也不改写其他服务的套餐。
- 菜单栏可显示简短 Agent 前缀，例如 `Codex 62% · Grok 94%`；同一账号连续多个数值只写一次前缀。在设置中关闭“显示 Agent 前缀”可恢复纯数值。选择会保留，失效读数显示 `—`。
- Codex 剩余点数也可单独开启，菜单栏使用 `44.7k` 等紧凑数值，悬停显示准确点数。
- 有效额度余量较多且临近重置时，在菜单栏下方显示约 6 秒的轻量提醒，同一账号/窗口/周期只提醒一次。不会进入系统通知中心或抢焦点，可在设置中关闭，并遵守系统减少动态效果偏好。
- 显示服务商提供的额度窗口、剩余比例、重置倒计时，以及可用时的 credits 和重置卡数量。
- 菜单栏弹窗的“重置日历”按月汇总已接入账号的已知重置日期；点击日期查看账号、平台、额度窗口和准确时刻，支持切换月份、回到今天和选择时区。旧数据标为“待核实”，到期日期不推算下一周期，缺少日期的额度单独计数；Reserve、点数和重置卡到期不混入额度重置事件。
- 默认每 30 秒刷新，也可手动刷新。数据超过两分钟、时间不可信或额度窗口已重置时，显示过期状态。
- 启动时载入最近缓存并检查时效；刷新失败时显示网络或登录状态，避免把旧数据当成当前余额。
- 多账号列表默认显示紧凑摘要，点击账号展开详细额度；秒级倒计时只更新展开的详情，全局时效状态约每 15 秒检查一次。
- 可在设置中开启登录时启动。

不同产品的额度单位不同：百分比、tokens、消息数和 credits 分别展示，不能相加成一个可靠的“总 tokens”。服务商没有提供的值会显示为缺失，不估算成余额。ChatGPT 普通聊天和 Dots 暂无经验证的独立额度接口，TokenBar 不把它们重复计算为新账号额度。

## 安装与运行

需要 macOS 14 或更高版本。从 [GitHub Release](https://github.com/robbywang25/tokenbar/releases/tag/v0.2.4) 下载 DMG，将 TokenBar 拖入 Applications，先打开应用接入自己的账号，再在桌面右键“编辑小组件”中添加 TokenBar。下载安装包不需要开发工具。

源代码构建需要包含 Swift 5.9 或更高版本的 Xcode Command Line Tools，不依赖第三方 Swift 包。

```sh
xcode-select --install # 尚未安装开发工具时运行
swift test
scripts/build-app.sh
open dist/TokenBar.app
```

本地构建默认只包含当前 Mac 的架构，并使用 ad-hoc 签名。构建完成后可将 `dist/TokenBar.app` 拖到“应用程序”文件夹，再从那里运行。菜单栏齿轮中的“登录时启动”使用 macOS 登录项；系统要求批准时，到系统设置的登录项中允许 TokenBar。

如果取得经过公证的正式 DMG，打开后把 TokenBar 拖到 Applications 即可。当前源码构建和 CI 预览产物不代表已经通过公证，不应作为已公证版本宣传。

## 接入自己的账号

首次启动为空列表。点击“添加账号”，选择服务商和数据来源，再点“验证并添加”。应用验证成功后才保留配置；账号使用独立 UUID，支持同时接入多个账号。邮箱由来源提供，作为账号主标题；不显示个人名称。

| 来源 | 接入方式 | 范围与限制 |
| --- | --- | --- |
| Codex | 已登录客户端的本地凭据 JSON | 默认路径为 `~/.codex/auth.json`；可明确指定其他账号的凭据文件。需要现有订阅登录，普通 API key 不等同于订阅额度权限。 |
| Claude Code | 已有钥匙串条目或凭据 JSON | 选择现有登录对应的 Keychain service，或明确指定凭据文件。后台读取不会反复弹出系统授权窗口；无法读取时可改用现有凭据文件。 |
| Grok Build | 已安装并登录的 Grok CLI | 通过 ACP 初始化和只读账单查询读取当前 CLI 登录。需明确选择 CLI 路径；当前适配器不切换或创建 Grok 登录。 |
| 通用 JSON | 本地文件、HTTPS 或 SSH 远程文件 | 适合其他服务商、团队网关或自建适配器。HTTPS 可选 Bearer 由 macOS Keychain 保存；SSH 复用用户已有的配置与登录能力。 |

TokenBar 复用你明确选择的现有登录，不代替官方客户端登录，也不实现跨服务商的通用 OAuth 流程。登录失效后，先在官方客户端重新登录，再刷新 TokenBar。连接多个账号时，每个账号应对应自己的凭据或数据源；同一身份的重复接入会被拒绝。服务商缺少稳定身份信息时，去重能力受返回信息限制。

“移除此账号”只移除 TokenBar 的配置、缓存读数和该连接专用的 Bearer，不会退出官方客户端或删除原有服务商登录。

### 通过 SSH 读取已有额度文件

如果额度采集器已经在自己的服务器上运行，可以直接接入它输出的 JSON 文件。在 JSON 数据源中选择“SSH”，填写“SSH 主机别名”“远程 JSON 文件绝对路径”，以及需要展示的源账号 ID。多账号文件目前按账号逐个添加，可填写“服务名称”区分不同来源；同一文件无需为每个账号部署一份。别名和路径由每位用户自行配置，应用不预置管理服务器或个人账号。

SSH 接入使用系统 SSH 和既有的密钥或 agent，启用严格主机密钥检查和非交互模式。主机栏只接受字母、数字、点、下划线和连字符组成的别名，用户名、端口及密钥应配置在已有的 `~/.ssh/config` 中。该主机必须已在你的 SSH 配置和信任记录中可用；TokenBar 不保存 SSH 密码，不自动接受新主机密钥，也不修改 SSH 配置。

应用只在远端执行读取指定文件的 `cat`。只有该文件需要已有的提权读取权限时，才勾选“使用已有 sudo 只读权限”，通过 `sudo -n` 读取；这要求远端事先具备无交互授权，应用不会设置 sudo 规则、请求密码或扩展权限。远程读取最多等待 20 秒，文档最大 2 MiB；同一 SSH 数据源的多个账号在 5 秒内共享一次读取结果。

这一方式直接在应用内读取已有快照，不安装额外的 LaunchAgent、服务器或采集服务。源文件的生成和更新仍由你已有的采集器负责；连接成功不会让过期快照变成实时数据。

## 通用数据源格式

可以使用单账号对象，或下面这样的多账号文档。多账号文档需要在接入时填写准确的账号 ID；省略账号 ID 时，来源中必须恰好只有一个账号。

```json
{
  "schemaVersion": 1,
  "collectedAt": "2026-10-09T00:00:00Z",
  "accounts": [
    {
      "id": "example-personal",
      "status": "connected",
      "lastSuccessAt": "2026-10-09T00:00:00Z",
      "profile": { "email": "personal@example.com" },
      "identity": { "provider": "example", "accountID": "stable-account-id" },
      "windows": [
        {
          "id": "five-hour",
          "label": "5 小时",
          "remainingPercent": 62.5,
          "unit": "percent",
          "resetsAt": "2026-10-09T05:00:00Z",
          "quotaGroup": "default"
        }
      ],
      "credits": { "remaining": 12.5, "unlimited": false },
      "resetCredits": { "available": 0, "cards": [] }
    }
  ]
}
```

上面的数值和时间只是示例。生产者应写入实际采集时间；不要在每次读取时把旧余额重新标记为刚刚采集。`lastSuccessAt` 或文档的 `collectedAt` 缺失、超过两分钟、在未来超过一分钟，或窗口已重置时，读数不会标成实时。

- `status` 可为 `connected`、`stale`、`needs_auth`、`unavailable`、`not_configured` 或 `unsupported`。
- 每个 `windows` 项至少提供 `remainingPercent`（0–100）、非负 `remaining` 或 `unlimited: true`。可附带不小于 `remaining` 的 `limit`。
- `unit` 支持 `percent`、`tokens`、`requests`、`messages`、`credits` 和 `USD`。`startsAt`、`resetsAt` 使用 ISO 8601 时间；`model` 是可选模型名称。
- `quotaGroup` 支持 `default`、`reserve`、`code-review` 和 `additional`，便于保留不同额度池的边界。
- `identity` 可选，用于识别不同数据源中的同一账号。它应包含服务商名和稳定账号 ID，不应包含访问令牌。
- `subscription.planName` 是可选的套餐名；`subscription.planMultiplier` 接受数值 `5`、`10`、`20`、`25`、`50`，字符串或不支持的值会被忽略。Codex 的显示倍率还会按具体套餐核对；账单和价格字段不读取、不缓存。
- 文档最大 2 MiB，每个账号最多 64 个额度窗口。HTTPS 地址不能包含用户名、密码、查询参数或片段，也不跟随重定向。需要鉴权时使用独立 Bearer 输入框。

只有你选定的本地路径、HTTPS 端点或 SSH 远程文件会被读取。自建端点和远程采集器负责向其服务商获取数据；TokenBar 不会自动接管该服务商的账号权限。JSON 中已有的“需要登录”“未接入”或“暂无独立额度”状态可保留展示，不会被虚构为可用余额。

## 开发与打包

### 桌面小组件

支持 WidgetKit 的签名构建可添加 macOS 桌面小组件：在桌面右键选择“编辑小组件”，搜索 `TokenBar`。小、中、大尺寸分别显示 1、3、6 个账号，按使用紧急程度排序，同等条件保留菜单栏选择的优先顺序。邮箱作为主标题，显示剩余比例、点数、套餐倍率和实际采集时间；每个可见额度窗口展示自身的重置日期和时分（如 `10/18 13:16`，使用 Mac 当前时区）；点数不套用额度窗口的重置时间。重置卡数量独立显示，已知为 0 时也会保留，不占用额度指标位置。点按小组件可打开 TokenBar。

紧急程度表示“为了在重置前用完，需要加快使用的程度”：日均需用 = 剩余百分比 ÷ 距重置天数。以最长的有效常规额度周期为准（如每周优先于 5 小时），与整个周期的正常日均比较，达到 1.5 倍标“优先”，达到 2 倍标“紧急”，其他有效余量标“正常”。例如每周额度剩 60%、两天后重置，需要每天用 30%，约为每周正常日均的 2.1 倍，显示“紧急”。同级按日均需用从高到低，再按更早重置排序。Cursor 仅使用“其他模型”额度（JSON 窗口 ID 为 `api`）评估紧急程度和排序，自家模型 `auto` 保留展示；其他模型为零或缺失时不会回退到自家模型。

没有明确周期起止、已用完、无限额或过期读数不计算紧急程度，也不回退到其他额度池；Reserve 不参与计算。标签旁会标明所用窗口（如“每周 · 需用 30%/天”），避免与另一列的短周期额度混淆。

短暂未更新的读数仍按原时效规则置灰，但排序参考最近一次有效额度，距真实来源观测满 1 小时后才置底；重新读取相同旧数据不会延长宽限。恢复有效更新后重新按正常紧急程度排序。排序宽限不延长读数的实时有效期。

主程序将最小展示快照写入 App Group，扩展不读取凭据、不连接网络，也不执行 SSH。主程序需继续运行以采集新读数。WidgetKit 决定实际刷新时机；旧读数会标为“上次”，需要登录或未知状态不会变成零余额。

小组件要求主程序和扩展使用同一真实 Apple 签名团队。默认 ad-hoc 构建及旧 0.1.6 下载包是菜单栏版本；0.2.4 的正式签名下载包包含小组件。使用已有开发签名进行本机验证：

```sh
TOKENBAR_SIGN_IDENTITY='Apple Development' scripts/build-app.sh --universal --with-widget
```

维护者分发含小组件的安装包时需使用 Developer ID 签名并完成公证和验收。Apple Development 签名只用于本机开发验证；不要将 ad-hoc 菜单栏包标为支持桌面小组件。详见 [发布说明](RELEASE.md)。

### 菜单栏预览构建

```sh
swift test
scripts/build-app.sh --universal
scripts/package-release.sh --universal
```

输出在 `dist/`：独立应用、ZIP、DMG 和对应 SHA-256 文件。`--arch arm64` 或 `--arch x86_64` 可单独指定架构。CI 构建 Universal 预览 ZIP，并运行测试和应用包检查；CI 产物使用 ad-hoc 签名。

无需账号即可查看内存中的演示数据：

```sh
open dist/TokenBar.app --args --demo --show
```

演示数据是合成值，不代表真实余额。开发适配器时应使用合成 fixture，避免提交凭据、邮箱、账单或个人路径。

## 隐私、兼容性与支持

TokenBar 不包含遥测、广告、分析 SDK 或开发者后台。账号配置和最近读数留在本机，具体字段、网络边界与删除方式见 [隐私说明](PRIVACY.md)。

Codex、Claude 和 Grok 的兼容接口可能变更，读数可用性取决于上游服务、现有登录和权限。TokenBar 与这些服务商没有隶属关系。当前版本不包含自动更新器。

报告问题时，请在发布仓库的 Issues 中提供 macOS 版本、TokenBar 版本、服务商类型和不含个人信息的错误状态。不要附上凭据文件、Bearer、Keychain 内容或原始私有接口响应。
