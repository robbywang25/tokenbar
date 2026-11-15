# TokenBar 0.4.3 (27)

God 新登录使用 `auth.robby.wang`。已登录旧身份服务的用户可以在账户区选择“更新登录”，完成新页面的设备授权；确认完成前，现有登录、账号资料和同步设置继续保留。

新授权必须经 God API 验证为同一账户，并成功保存到系统钥匙串后才替换旧会话。取消、账号不一致或保存失败不会清除原登录。新旧会话始终向各自的身份服务刷新和撤销令牌，客户端只接受两个精确的受信身份地址。

账号身份和 God API 地址保持不变，因此既有账户资料、显示偏好及同步目录继续使用原身份。服务端必须保持同一账户的稳定 `user.id`，并先启用新域的设备授权配置；不能通过改写令牌的签发地址代替迁移。

## 验证与分发边界

- 完整 Swift 测试 267 项通过，含 10 项新迁移回归：新旧会话恢复/刷新隔离、陌生issuer拒绝、取消时保留刷新、同一用户校验、保存失败、退出竞态与新会话重启恢复。
- 本机 Universal Release 构建验证了 Apple silicon 与 Intel 两种架构。本机已安装并由本人完成新域授权和同步，服务器已记录同一新域会话的自动续期。Intel 真机和不中断的旧钥匙串会话升级仍未单独实测。
- 本版本只调整认证、对应账户操作和版本信息；没有改动 provider 接入、额度计算、采集或Widget数据权限。
- 正式安装包包含现有 WidgetKit 扩展，主应用和扩展均已通过同一 Developer ID 签名；App／DMG 公证、票据装订、Gatekeeper 与最终分发校验通过。

## GitHub 发布完成

2026-11-15 07:03:17 PST，已将核验后的草稿发布为 [TokenBar v0.4.3](https://github.com/robbywang25/tokenbar/releases/tag/v0.4.3)，并设为 Latest。发布后 API 回读确认 `draft=false`、`prerelease=false`，Latest 指向同一 release；仓库保持原有 public 状态。

标签 `v0.4.3` 固定指向 `a4f4632bf75fee19969147433cbd47a43e942d95`。三个 GitHub 资产已全部重新下载，与本地原件逐字节一致；GitHub digest、实际 SHA-256 与校验和文件相符：

| 资产 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `TokenBar-0.4.3-universal-widget.dmg` | 4,717,657 | `f57e355ec4eeb3c04e77dbe2edc16477922a6e6ebb42fb49bf6c8abd1f89e49a` |
| `TokenBar-0.4.3-universal-widget.zip` | 4,061,259 | `267b0df910509a6f44a87c0159523098a99439aefc49b9f6c6be16d5300a26fc` |
| `TokenBar-0.4.3-universal-widget-SHA256SUMS.txt` | 204 | `a25646e4ecc118136b68c77ff0c727c6ae7644a6a68190bd3368d9345887376c` |

本人已确认新域登录与同步正常；协调任务观察到同一授权的 9 条刷新令牌记录（初始 1 条、轮换 8 条）。这项实际验收不扩大为 Intel 真机或长期登录有效性的证明。此次 GitHub 发布没有修改 iOS、手机、服务端或其他仓库。
