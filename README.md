# HanimeApp — iOS 网页壳 App

一个基于 `WKWebView` 的 iOS 壳应用，加载 https://hanime1.me/ 并与其内容完整交互（登录、播放、收藏等都在 App 内完成，数据与 Safari 独立）。

## 功能

- 全屏 WebView 加载目标网址，顶部无遮挡（安全区适配）
- 底部工具栏：返回 / 刷新（加载中变为停止）/ 前进
- 支持系统手势滑动返回/前进
- 站内视频自动播放（`allowsInlineMediaPlayback`）
- 站外链接自动交给系统 Safari 打开，站内一切请求正常放行
- Cookie / 登录状态持久保存（`WKWebsiteDataStore.default()`）

## 项目结构

```
HanimeApp/
├── HanimeApp.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/HanimeApp.xcscheme
├── HanimeApp/
│   ├── HanimeApp.swift      # App 入口
│   └── ContentView.swift    # WebView + 工具栏
└── .github/workflows/build_ipa.yml   # 云端打包未签名 IPA
```

## 方式 A：有 Mac（最简单）

1. 把 `HanimeApp` 整个文件夹拷到 Mac 上，双击 `HanimeApp.xcodeproj` 打开。
2. 左侧选中项目 → Signing & Capabilities：
   - 勾选 Automatically manage signing
   - Team 选择你的 Apple ID（免费个人账号即可）
   - Bundle Identifier 建议改成一个专属的，如 `com.你的名字.hanimeapp`
3. iPhone 连接 Mac → 选中设备 → 点 ▶ 运行。首次运行需在手机上信任开发者：
   设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → 信任。

> 免费账号签名 **7 天有效**，到期后重新运行一次即可；每 7 天最多签 3 个 App。
> 付费开发者账号（$99/年）签名 1 年有效。

## 方式 B：没有 Mac（Windows 云端打包）

1. 在 GitHub 新建一个仓库，把整个 `HanimeApp` 文件夹内容（含 `.github/` 目录）推送上去。
2. 仓库页面 → Actions → `Build Unsigned IPA` → Run workflow。
3. 运行完成后在对应 run 的 Artifacts 里下载 `HanimeApp-ipa`（未签名 IPA）。
4. Windows 上用 **Sideloadly**（需先装 iTunes + iCloud 官方版）或 **AltServer + AltStore** 把 IPA 自签安装到手机：
   - 手机连电脑 → 打开 Sideloadly → 拖入 IPA → 填你的 Apple ID → Start。
   - 安装后同样到 设置 → 通用 → VPN与设备管理 → 信任开发者。
   - 免费账号同样 7 天到期，重新签一次即可；付费证书可配合"轻松签/Esign"等在设备上直接续签。

## 方式 C：已有自签名证书（p12 + 描述文件）

如果证书是别人/三方平台签发的，用 轻松签（Esign）、esign-in-app、TrollStore 等直接对未签名 IPA 重签即可。

## 自定义

- **改网址**：`HanimeApp/ContentView.swift` 中搜索 `https://hanime1.me/` 替换即可。
- **改 App 名称**：Xcode 里改 Target 名，或在 pbxproj 中把 `PRODUCT_NAME` 换成固定字符串。
- **改图标**：在 Xcode 中添加 AppIcon 资源（Assets.xcassets）。

## 注意

- 站点内容合规、账号安全、证书来源等由使用者自行负责；请勿将本项目用于任何商业分发。
- 免费证书续签需要 7 天内用同一台电脑（AltServer/Sideloadly）保持签发。
