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
- `TokenBar-0.2.2-universal.zip`
- `TokenBar-0.2.2-universal.dmg`
- `TokenBar-0.2.2-universal-SHA256SUMS.txt`

可使用 `TOKENBAR_VERSION` 和 `TOKENBAR_BUILD_NUMBER` 设置版本，例如：

```sh
TOKENBAR_VERSION=0.2.2 TOKENBAR_BUILD_NUMBER=12 scripts/package-release.sh --universal
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

Apple Development 签名的小组件包名带有 `-widget-development`，例如 `TokenBar-0.2.2-universal-widget-development.zip`。它用于本机验收，不作为面向所有用户的签名安装包发布。正式 Developer ID 小组件包使用 `-widget` 后缀；默认菜单栏版保持不带后缀的文件名。`--skip-build` 会识别已有扩展，并验证内外签名、共享组、版本和架构；指定 `--with-widget` 但应用缺少扩展时会失败。

## 3. Developer ID 签名与公证前检查

使用维护者自己的 Developer ID Application 身份构建正式小组件版。下面的身份和 Team ID 是占位值，必须替换为本次确认的真实身份；不要将私钥、密码或公证凭据写入仓库：

```sh
export TOKENBAR_SIGN_IDENTITY='Developer ID Application: Example Organization (TEAMID)'
scripts/build-app.sh --universal --with-widget
scripts/verify-release.sh --app dist/TokenBar.app --team-id TEAMID --pre-notary
scripts/package-release.sh --skip-build --with-widget --no-dmg
```

`--pre-notary` 只检查应用的提交准备状态，不声称已公证。它要求主应用和扩展都具有 Apple 信任链下的 Developer ID 签名、相同 Team ID/共享组、两个架构的 Hardened Runtime 和安全时间戳，以及符合预期的最小 entitlements；Apple Development 和 ad-hoc 签名会被明确拒绝。它还核对实际 Mach-O 最低系统版本、WidgetKit 入口和内外版本一致性，然后执行 `syspolicy_check notary-submission`。

有些 macOS 版本的公证前检查会把尚未取得票据的候选交给 Gatekeeper 拒绝。只有上述签名与结构门禁已经通过，且独立 `spctl` 返回码为 `3`、精确原因为 `source=Unnotarized Developer ID` 时，验证器将其分类为 `policyStatus: notarization-pending` 并允许继续提交。这个结果只表示“等待公证”，不能称为已经公证或可以正式发布；其他策略错误仍然失败。正常公证前检查成功则输出 `notary-submission-ready`。

验证器的离线回归可运行 `python3 -B -m unittest discover -s scripts/tests -p test_verify_release.py -v`。测试使用合成文件与命令替身，不签名、挂载磁盘、提交公证或读取凭据；其中明确验证 `codesign --test-requirement` 的表达式必须使用 `=` 前缀，避免被工具误认为要求文件路径。

构建先签内嵌扩展再签主应用。主应用需要读取用户明确选择的凭据并运行 CLI，未启用 App Sandbox；WidgetKit 扩展独立开启沙盒且没有网络权限。此直接分发包不是 Mac App Store 提交包。

## 4. 公证、装订与最终校验

维护者通过既有安全输入流程配置 `notarytool` Keychain profile，例如 `TokenBar-Notary`。验证脚本不读取 Keychain、不接收认证参数、不创建凭据，也不自动提交或上传任何文件；构建和打包中的签名由 `codesign` 使用系统管理的既有签名身份完成。

以下命令以当前 `0.2.2` Universal 小组件版为例；版本变化时对应调整文件名。保持上一节导出的 `TOKENBAR_SIGN_IDENTITY`，先提交含 Developer ID 应用的初始 ZIP：

```sh
xcrun notarytool submit dist/TokenBar-0.2.2-universal-widget.zip \
  --keychain-profile TokenBar-Notary --wait
```

只有服务端状态为 `Accepted` 才继续，保留提交 ID 和结果。如果被拒绝，读取该提交的公证日志并修复。ZIP 本身不支持装订，先将票据装订到独立应用并验证：

```sh
xcrun stapler staple dist/TokenBar.app
xcrun stapler validate dist/TokenBar.app
scripts/package-release.sh --skip-build --with-widget
```

这次重新打包让最终 ZIP 和 DMG 都包含已经装订的应用；因仍保留 Developer ID 环境变量，DMG 也使用该身份签名并获得安全时间戳。`--skip-build` 不重新编译或重签应用。不要在装订后再次运行普通 build 覆盖它。

接着公证新 DMG，只有其结果也为 `Accepted` 才装订 DMG。装订改变 DMG 字节，因此最终校验文件必须在这一步之后生成：

```sh
xcrun notarytool submit dist/TokenBar-0.2.2-universal-widget.dmg \
  --keychain-profile TokenBar-Notary --wait
xcrun stapler staple dist/TokenBar-0.2.2-universal-widget.dmg
xcrun stapler validate dist/TokenBar-0.2.2-universal-widget.dmg
(
  cd dist
  shasum -a 256 TokenBar-0.2.2-universal-widget.zip TokenBar-0.2.2-universal-widget.dmg \
    > TokenBar-0.2.2-universal-widget-SHA256SUMS.txt
)
scripts/verify-release.sh \
  --app dist/TokenBar.app --team-id TEAMID \
  --zip dist/TokenBar-0.2.2-universal-widget.zip \
  --dmg dist/TokenBar-0.2.2-universal-widget.dmg \
  --checksums dist/TokenBar-0.2.2-universal-widget-SHA256SUMS.txt
```

最终验证先核对恰好对应 ZIP/DMG 的两个 SHA-256，强制检查 app/DMG 装订票据、Gatekeeper 和现代 macOS `syspolicy_check distribution`；这里不接受 `notarization-pending`，缺少工具或任何一步失败都会拒绝发布。之后校验 ZIP 路径、文件类型和解压上限，再解到临时目录；DMG 只读挂载且不打开 Finder。两种归档里的应用必须与独立已验证应用逐文件一致，内含签名和票据也必须通过；结束时卸载并清理临时目录，再复核交付文件的 SHA。整个过程不运行应用、不修改原产物，不签名、装订或提交公证；系统的信任和票据验证可能访问 Apple 服务。

验证成功后冻结这组三个交付文件。若再次打包、签名、装订或修改应用，重新走受影响的公证/装订步骤并重算校验文件；不能保留旧 SHA 或把初次未装订 ZIP 当成最终下载包。公开 GitHub Release 与自托管下载页必须引用同一组已验收产物。

## 5. 发布验收

先完成签名和 Gatekeeper 检查：

```sh
codesign --verify --deep --strict --verbose=2 dist/TokenBar.app
spctl --assess --type execute --verbose=2 dist/TokenBar.app
spctl --assess --type open --context context:primary-signature --verbose=2 \
  dist/TokenBar-0.2.2-universal-widget.dmg
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
