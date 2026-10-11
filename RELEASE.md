# TokenBar 发布说明

项目可生成独立 macOS 应用和分发文件，但可构建不等于已通过公开发布验证。默认构建是 ad-hoc 签名的菜单栏版；桌面小组件通过 `--with-widget` 显式启用，需要真实的 Apple Development 或 Developer ID Application 身份。Apple Development 用于本机开发验收，不能替代面向普通用户的 Developer ID 签名与公证。

## 1. 本地验证与预览包

在 macOS 上安装 Xcode Command Line Tools，确认使用支持 macOS 14 的 SDK，然后执行：

```sh
swift test
scripts/package-release.sh --universal
```

默认生成的 Universal 菜单栏版包含 Apple silicon 和 Intel 架构，不内嵌桌面小组件；产物位于 `dist/`：

- `TokenBar.app`
- `TokenBar-0.2.0-universal.zip`
- `TokenBar-0.2.0-universal.dmg`
- `TokenBar-0.2.0-universal-SHA256SUMS.txt`

可使用 `TOKENBAR_VERSION` 和 `TOKENBAR_BUILD_NUMBER` 设置版本，例如：

```sh
TOKENBAR_VERSION=0.2.1 TOKENBAR_BUILD_NUMBER=10 scripts/package-release.sh --universal
```

每次正式发布应递增版本和 build number。`TOKENBAR_DIST_DIR` 可指定输出目录；默认只写入本仓库的 `dist/` 和 `.build/`。脚本不会上传文件或创建公开 release。

## 2. 本机桌面小组件构建

使用本机已有的 Apple Development 身份构建小组件，无需创建证书、注册新 App Group 或修改 Apple 账号权限。下面的姓名和证书后缀是占位值，必须替换为本机已有身份：

```sh
TOKENBAR_SIGN_IDENTITY='Apple Development: Example Developer (CERTIFICATE_SUFFIX)' \
  scripts/build-app.sh --universal --with-widget
```

`--with-widget` 配合默认 ad-hoc 身份时会在编译前失败，避免生成无法授权共享容器的小组件包。没有开发证书的源码使用者仍可按上一节构建菜单栏版。

脚本从实际代码签名读取 `TeamIdentifier`，生成 `<TeamIdentifier>.wang.robby.tokenbar` 共享组，并将同一值写入主应用及扩展的 `TokenBarAppGroup` Info.plist 字段和 App Group entitlement。证书名称括号中的后缀不一定是 Team ID，不能用它推算组名。这个 macOS 专用组名由系统核验签名团队，不要求 provisioning profile 或 Developer Portal 注册；`group.` 前缀方案具有不同的描述文件要求。参见 [Apple 的 App Group 说明](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)。

应用包内扩展位于 `TokenBar.app/Contents/PlugIns/TokenBarWidget.appex`，bundle ID 为 `wang.robby.tokenbar.widget`。扩展开启 App Sandbox，只接收共享快照，不获得网络、原账号凭据、SSH 或额外文件访问权限；主应用继续使用既有账号接入方式。两者版本、build number、架构和签名身份一致，先签扩展，再签外层应用。

WidgetKit 扩展直接由本机 macOS SDK 编译，不需要生成 Xcode 工程。脚本采用 Xcode app-extension 产品类型的 `_NSExtensionMain` 链接入口，并设置 `com.apple.widgetkit-extension` 扩展点；普通 Swift 可执行程序的入口不是可替代的扩展打包设置。

安装到 Applications 并打开主应用后，在 macOS 的“编辑小组件”中添加 TokenBar。数据更新由系统 WidgetKit 调度，不承诺与菜单栏相同的 30 秒刷新频率。主应用没有新快照时，已经过期的额度应显示为上次读数或待更新。

如需保留本机开发包，可以执行：

```sh
scripts/package-release.sh --skip-build --with-widget
```

Apple Development 签名的小组件包名带有 `-widget-development`，例如 `TokenBar-0.2.0-universal-widget-development.zip`。它用于本机验收，不作为面向所有用户的签名安装包发布。正式 Developer ID 小组件包使用 `-widget` 后缀；默认菜单栏版保持不带后缀的文件名。`--skip-build` 会识别已有扩展，并验证内外签名、共享组、版本和架构；指定 `--with-widget` 但应用缺少扩展时会失败。

## 3. Developer ID 签名

维护者需要自己的 Apple Developer Program 账号和可用的 Developer ID Application 身份。先用以下命令列出本机可用签名身份，不要将私钥或密码写入仓库：

```sh
security find-identity -v -p codesigning
```

按实际身份名称构建，示例中的名称只是占位值：

```sh
export TOKENBAR_SIGN_IDENTITY='Developer ID Application: Example Organization (TEAMID)'
scripts/package-release.sh --universal
```

如发布包含桌面小组件的版本，在上述命令追加 `--with-widget`。脚本为应用及内嵌扩展启用 Hardened Runtime 和安全时间戳，并在打包前验证签名。DMG 也使用指定的 Developer ID 身份签名。主应用需要读取用户明确选择的客户端凭据并运行 CLI，因此未启用 App Sandbox；WidgetKit 扩展独立开启沙盒。此直接分发包不是 Mac App Store 提交包。

## 4. Apple 公证与装订

使用 `xcrun notarytool store-credentials` 按本机工具提示，把维护者自己的公证凭据保存为 Keychain profile，例如 `TokenBar-Notary`。不要将凭据、密码或证书存入源码或 CI 日志。

以下示例针对 `0.2.0` Universal 菜单栏版，其他版本需相应替换文件名；小组件版所有归档文件名增加 `-widget` 后缀。保持上一步的 `TOKENBAR_SIGN_IDENTITY` 环境变量，先公证包含签名应用的 ZIP：

```sh
xcrun notarytool submit dist/TokenBar-0.2.0-universal.zip \
  --keychain-profile TokenBar-Notary --wait
```

只有公证结果为 `Accepted` 才继续。如果被拒绝，读取对应的 notarytool log 并修复问题。将票据装订到应用，再重新打包，确保 ZIP 和 DMG 都含有装订后的应用：

```sh
xcrun stapler staple dist/TokenBar.app
xcrun stapler validate dist/TokenBar.app
scripts/package-release.sh --skip-build
xcrun notarytool submit dist/TokenBar-0.2.0-universal.dmg \
  --keychain-profile TokenBar-Notary --wait
```

DMG 公证也必须为 `Accepted`。随后装订 DMG 并重新生成校验文件，因为装订会改变文件内容：

```sh
xcrun stapler staple dist/TokenBar-0.2.0-universal.dmg
xcrun stapler validate dist/TokenBar-0.2.0-universal.dmg
(
  cd dist
  shasum -a 256 TokenBar-0.2.0-universal.zip TokenBar-0.2.0-universal.dmg \
    > TokenBar-0.2.0-universal-SHA256SUMS.txt
)
```

## 5. 发布验收

先完成签名和 Gatekeeper 检查：

```sh
codesign --verify --deep --strict --verbose=2 dist/TokenBar.app
spctl --assess --type execute --verbose=2 dist/TokenBar.app
spctl --assess --type open --context context:primary-signature --verbose=2 \
  dist/TokenBar-0.2.0-universal.dmg
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
- 反复打开/关闭设置、滚动到两端、展开/收起账号，并跨越至少两次自动刷新。操作停止后检查 CPU 是否回落及多轮内存是否趋于稳定；出现假死时先保留进程采样和系统诊断报告，不能仅用重启或测试通过认定修复。
- “登录时启动”可启用和关闭；卸载说明可执行。
- 对小组件版验证系统图库可找到 TokenBar，实际添加小、中、大尺寸后可读取共享快照；登录失败、断网和超过快照新鲜期限时正确显示未知或上次读数。点击小组件返回菜单栏界面，更新主应用后再次检查扩展签名和图库行为。
- `pluginkit -m -v -i wang.robby.tokenbar.widget` 可作为扩展登记诊断，但登记成功不代表系统已取得 widget descriptors、可在图库选择或已在桌面渲染；这些需要分别验收。构建脚本不自动登记、添加桌面小组件或重启系统组件。
- 在实际 Apple silicon 和 Intel Mac 上分别运行。Universal 构建和 `lipo` 检查只能证明包含两种架构，不能替代两类设备验收。
- 发布文件及截图不含个人账号、邮箱、凭据、账单数据或私有端点。

发布仓库不得包含任何用户的 SSH 主机别名、远程私有路径或预配置账号列表。每位用户在首次启动后明确接入自己的数据源；已有个人安装的连接配置不能打入通用应用包。

发布说明应明确写出已验证的系统、架构和适配器，以及仍未验证的项目。不得把单元测试通过、开发者机器运行成功或签名成功描述为所有账号都已验证。

## 6. 发布与后续维护

确认仓库许可证和版本记录齐全后，再把最终 ZIP、DMG 和校验文件上传到选定发布渠道。未经公证的安装包只作为明确标注的测试版发布。发布动作由维护者主动执行，当前脚本和 CI 都不执行公开上传。

CI 在 macOS runner 上运行测试、构建默认 Universal 菜单栏预览 ZIP，并检查签名结构、菜单栏模式及架构。CI 不使用真实账号、不持有发布证书，也不提交 Apple 公证；因此 CI 的默认归档不能当成已验收的小组件版本。服务商兼容接口发生变化时，应先用脱敏 fixture 更新解析与测试，再验证用户实际登录的只读访问。
