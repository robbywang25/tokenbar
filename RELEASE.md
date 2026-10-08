# TokenBar 发布说明

项目可生成独立 macOS 应用和分发文件，但可构建不等于已通过公开发布验证。默认构建是供本机验证的 ad-hoc 签名预览版；Apple Development 证书不能替代公开分发所需的 Developer ID Application 证书。

## 1. 本地验证与预览包

在 macOS 上安装 Xcode Command Line Tools，确认使用支持 macOS 14 的 SDK，然后执行：

```sh
swift test
scripts/package-release.sh --universal
```

生成的 Universal 应用包含 Apple silicon 和 Intel 架构，产物位于 `dist/`：

- `TokenBar.app`
- `TokenBar-0.1.0-universal.zip`
- `TokenBar-0.1.0-universal.dmg`
- `TokenBar-0.1.0-universal-SHA256SUMS.txt`

可使用 `TOKENBAR_VERSION` 和 `TOKENBAR_BUILD_NUMBER` 设置版本，例如：

```sh
TOKENBAR_VERSION=0.1.1 TOKENBAR_BUILD_NUMBER=2 scripts/package-release.sh --universal
```

每次正式发布应递增版本和 build number。`TOKENBAR_DIST_DIR` 可指定输出目录；默认只写入本仓库的 `dist/` 和 `.build/`。脚本不会上传文件或创建公开 release。

## 2. Developer ID 签名

维护者需要自己的 Apple Developer Program 账号和可用的 Developer ID Application 身份。先用以下命令列出本机可用签名身份，不要将私钥或密码写入仓库：

```sh
security find-identity -v -p codesigning
```

按实际身份名称构建，示例中的名称只是占位值：

```sh
export TOKENBAR_SIGN_IDENTITY='Developer ID Application: Example Organization (TEAMID)'
scripts/package-release.sh --universal
```

脚本为应用启用 Hardened Runtime 和安全时间戳，并在打包前验证签名。DMG 也使用指定的 Developer ID 身份签名。当前程序需要读取用户明确选择的客户端凭据并运行 CLI，因此此直接分发版本没有启用 App Sandbox；它不是 Mac App Store 提交包。

## 3. Apple 公证与装订

使用 `xcrun notarytool store-credentials` 按本机工具提示，把维护者自己的公证凭据保存为 Keychain profile，例如 `TokenBar-Notary`。不要将凭据、密码或证书存入源码或 CI 日志。

以下示例针对 `0.1.0` Universal 构建，其他版本需相应替换文件名。保持上一步的 `TOKENBAR_SIGN_IDENTITY` 环境变量，先公证包含签名应用的 ZIP：

```sh
xcrun notarytool submit dist/TokenBar-0.1.0-universal.zip \
  --keychain-profile TokenBar-Notary --wait
```

只有公证结果为 `Accepted` 才继续。如果被拒绝，读取对应的 notarytool log 并修复问题。将票据装订到应用，再重新打包，确保 ZIP 和 DMG 都含有装订后的应用：

```sh
xcrun stapler staple dist/TokenBar.app
xcrun stapler validate dist/TokenBar.app
scripts/package-release.sh --skip-build
xcrun notarytool submit dist/TokenBar-0.1.0-universal.dmg \
  --keychain-profile TokenBar-Notary --wait
```

DMG 公证也必须为 `Accepted`。随后装订 DMG 并重新生成校验文件，因为装订会改变文件内容：

```sh
xcrun stapler staple dist/TokenBar-0.1.0-universal.dmg
xcrun stapler validate dist/TokenBar-0.1.0-universal.dmg
(
  cd dist
  shasum -a 256 TokenBar-0.1.0-universal.zip TokenBar-0.1.0-universal.dmg \
    > TokenBar-0.1.0-universal-SHA256SUMS.txt
)
```

## 4. 发布验收

先完成签名和 Gatekeeper 检查：

```sh
codesign --verify --deep --strict --verbose=2 dist/TokenBar.app
spctl --assess --type execute --verbose=2 dist/TokenBar.app
spctl --assess --type open --context context:primary-signature --verbose=2 \
  dist/TokenBar-0.1.0-universal.dmg
lipo -verify_arch arm64 x86_64 dist/TokenBar.app/Contents/MacOS/TokenBar
```

正式发布前，还需在没有开发环境和既有 TokenBar 数据的新用户环境中检查：

- 从真实下载的最终 DMG 安装，Gatekeeper 正常允许打开，首次启动为空账号列表。
- 应用仅出现于菜单栏，弹窗可打开和关闭，没有 Dock 图标；退出后不再轮询。
- 使用用户自己的账号接入，正确显示额度、来源时间、重置时间和错误状态；无凭据时只显示明确的接入提示。
- 网络断开、登录过期及超过两分钟的数据均不会显示为实时。
- 多账号分别显示，同一身份不会重复计数；移除账号后不再查询，并清除专用 Bearer。
- JSON 的本地文件、HTTPS 和 SSH 三种接入均保留真实源时间。SSH 只访问显式指定的主机别名及绝对路径；未知主机、需要交互登录或缺少读取权限时清楚失败。
- 验证 SSH 读取的 20 秒和 2 MiB 限制、同一来源 5 秒内读取合并，以及可选 `sudo -n` 只使用已有授权；连接和退出均不安装额外 LaunchAgent、修改 SSH 配置或启停远端采集器。
- 多账号滚动与展开流畅，秒级倒计时只更新展开详情；全局时效检查与默认 30 秒数据轮询按各自频率工作。
- “登录时启动”可启用和关闭；卸载说明可执行。
- 在实际 Apple silicon 和 Intel Mac 上分别运行。Universal 构建和 `lipo` 检查只能证明包含两种架构，不能替代两类设备验收。
- 发布文件及截图不含个人账号、邮箱、凭据、账单数据或私有端点。

发布仓库不得包含任何用户的 SSH 主机别名、远程私有路径或预配置账号列表。每位用户在首次启动后明确接入自己的数据源；已有个人安装的连接配置不能打入通用应用包。

发布说明应明确写出已验证的系统、架构和适配器，以及仍未验证的项目。不得把单元测试通过、开发者机器运行成功或签名成功描述为所有账号都已验证。

## 5. 发布与后续维护

确认仓库许可证和版本记录齐全后，再把最终 ZIP、DMG 和校验文件上传到选定发布渠道。未经公证的安装包只作为明确标注的测试版发布。发布动作由维护者主动执行，当前脚本和 CI 都不执行公开上传。

CI 在 macOS runner 上运行测试、构建 Universal 预览 ZIP，并检查签名结构、菜单栏模式及架构。CI 不使用真实账号、不持有发布证书，也不提交 Apple 公证。服务商兼容接口发生变化时，应先用脱敏 fixture 更新解析与测试，再验证用户实际登录的只读访问。
