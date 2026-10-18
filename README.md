![Artboard][NuggetLogo]

# GoldenNugget（移动版 · 简体中文）

释放设备全部潜力，支持 iOS 27！

用动态墙纸装扮你的设备、停用烦人的守护进程，还有更多功能！

> [!IMPORTANT]
> 本仓库是 [GoldenNugget Mobile](https://github.com/GoldenNugget-Team/GoldenNugget-mobile) 的**简体中文分支**：
> 应用界面、内置调整项名称与说明、运行日志、错误提示以及应用元数据均已汉化。
> 安装包由 GitHub Actions 的 macOS runner 使用 Xcode 编译发布，可在本仓库的
> [Releases](https://github.com/YiHoooong/GoldenNugget-mobile-ZH/releases) 页面下载。

如果你使用 Windows 或 Linux，请先安装[构建依赖](#构建要求)。

> [!NOTE]
> 使用本项目前请务必备份数据！GoldenNugget 可能会引发意外问题，防患于未然总是好的。我们不对设备造成的任何损坏负责。

> [!WARNING]
> **任何数据丢失或启动循环（bootloop）都与我们无关；如果出了问题，那是你自己的责任。**

## Discord 服务器
需要支持？欢迎加入我们的 [Discord 服务器][server]。

## 功能
<details>
<summary>iOS 26.2 - 27.0+</summary>

- PosterBoard（海报板）：动态墙纸与描述符。
  - 社区墙纸可以在[这里][WallpapersWebsite]或[这里][caplayground]找到
  - 使用 batter 文件自定义社区制作的墙纸
  - 可安装 MercuryPoster 中的设备专属墙纸
  - tendie 与 batter 文件的结构文档见 [documentation.md](documentation.md)
- 模板：自定义操作与文件编辑
  - batter 文件的结构文档见 [documentation.md](documentation.md)
- Springboard 选项（主屏幕/锁定屏幕）
  - 设置锁定屏幕脚注
  - 设置锁定屏幕闲置自动锁定时间
  - 重新载入界面后禁用自动锁定
  - 充电时禁用屏幕变暗
  - 禁用低电量提醒
  - 在锁定屏幕隐藏交流电源指示
  - 在锁定屏幕显示监管文本
  - 在截图中显示灵动岛
  - 为台前调度启用 AirPlay 支持
  - 在锁定屏幕显示红/绿认证线（效果见[此 issue](https://github.com/leminlimez/Nugget/issues/656)）
  - 在 iPad 上禁用浮动标签栏
- 内部选项
  - 在状态栏显示构建版本
  - 强制从右到左排版
  - 在主屏幕显示隐藏图标
  - 强制显示 Metal HUD 调试信息
  - iMessage 诊断
  - IDS 诊断
  - VC 诊断
  - App Store 调试手势
  - 备忘录 App 调试模式
  - 显示触摸点与调试信息
  - 隐藏重新载入界面图标
  - 粘贴时播放声音
  - 显示系统粘贴通知
- 禁用液态玻璃（iOS 26.0+）：
  - 忽略液态玻璃 App 构建检查（iOS 26.0+）
  - 强制 Solarium 回退（iOS 26.0+，在 iOS 27 上已失效）
- 禁用守护进程：
  - OTAd
  - UsageTrackingAgent
  - Game Center
  - 屏幕使用时间代理
  - 日志、转储与崩溃报告
  - ATWAKEUP
  - Tipsd
  - VPN
  - 中国 WLAN 服务
  - HealthKit
  - AirPrint
  - 辅助触控
  - iCloud
  - 互联网共享（即个人热点）
  - PassBook
  - Spotlight
</details>

## 从 Releases 安装
1. 打开本仓库的 [Releases](https://github.com/YiHoooong/GoldenNugget-mobile-ZH/releases) 页面。
2. 下载最新的 `GoldenNuggetMobile.ipa`（未签名）以及对应的 `.sha256` 校验文件。
3. 使用 AltStore、SideStore、LiveContainer 等侧载工具安装，安装时由工具完成签名。
4. 首次打开应用后，按应用内的初始设置指南完成隧道与配对。

> [!NOTE]
> IPA 由 CI 自动编译，未签名。使用前请自行核对 SHA-256。

## 构建与发布（CI）
本分支的编译与发布全部由 GitHub Actions 完成：

- `.github/workflows/build.yml`：每次推送自动编译未签名 IPA，并上传为构建产物（artifact）。
- `.github/workflows/release.yml`：手动触发（或推送 `v*` tag）后编译 IPA，并自动创建/更新
  GitHub Release，附带 IPA 与 SHA-256 校验文件。

本地构建方式（需要 macOS + Xcode 26+）：

```bash
xcodegen generate
./scripts/build-ipa.sh Release
# 产物：build/GoldenNuggetMobile.ipa（未签名）
```

## 贡献者

<div align="center">

**感谢每一位为项目做出贡献的人！** 🎉

<a href="https://github.com/goldennugget-team/goldennugget-mobile/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=goldennugget-team/goldennugget-mobile" />
</a>

想在这里看到你的名字？欢迎提交 [Pull Request](https://github.com/GoldenNugget-Team/GoldenNugget-mobile/pulls)！

</div>

## Star 历史

<a href="https://www.star-history.com/?type=date&repos=GoldenNugget-mobile%2FGoldenNugget-mobile">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=GoldenNugget-Team/GoldenNugget-mobile&type=date&theme=dark&legend=top-left&sealed_token=3Suw7Y0hFqwuBPijtmeM2A7pzK2ZCvEPoousYMJzOVFnPza-Aq5SzgNnEcgveIpQsBLEOL2QRtxwZbmaxn_S_3Lf9l0jINrMfRWkjFWGo3dVYCrFRpN6dA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=GoldenNugget-Team/GoldenNugget-mobile&type=date&legend=top-left&sealed_token=3Suw7Y0hFqwuBPijtmeM2A7pzK2ZCvEPoousYMJzOVFnPza-Aq5SzgNnEcgveIpQsBLEOL2QRtxwZbmaxn_S_3Lf9l0jINrMfRWkjFWGo3dVYCrFRpN6dA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=GoldenNugget-Team/GoldenNugget-mobile&type=date&legend=top-left&sealed_token=3Suw7Y0hFqwuBPijtmeM2A7pzK2ZCvEPoousYMJzOVFnPza-Aq5SzgNnEcgveIpQsBLEOL2QRtxwZbmaxn_S_3Lf9l0jINrMfRWkjFWGo3dVYCrFRpN6dA" />
 </picture>
</a>

<div align="center">
<br>如果觉得这个项目不错，欢迎点个 Star。</br>
</div>

> [!NOTE]
> ## Mobilegestalt
> 不要再来问了，这个功能永远不会再次实现。

## 构建要求
Xcode 26+ 或带 iOS 26+ SDK 的 xtool\
Rust（NeoSpring 与 airlift）\
Swift 6+（旧版本未测试，可能可用）\
macOS 15.6 Sequoia+ 或 Ubuntu 22.04+

# 贡献与复刻（Fork）
参见 [CONTRIBUTING.md](https://github.com/GoldenNugget-Team/GoldenNugget-mobile/blob/main/CONTRIBUTING.md)；
想复刻（fork）本项目，请参见 [FORKING.md](https://github.com/GoldenNugget-Team/GoldenNugget-mobile/blob/main/FORKING.md)。

## 致谢
- [awesomenull] 首席开发者
- [Wind0ws11Aero] 在开发过程中提供了大量帮助。
- [@mak5er](https://github.com/mak5er)：AirCard 开发者。
- [NeoSpring](https://github.com/rooootdev/neospring)：Swift 实现由 **[@skadz108](https://github.com/skadz108)** 和 **[@rooootdev](https://github.com/rooootdev)** 完成，**[@neonmodder123](https://github.com/neonmodder123)** 提供了 WebKit GPU 进程 respring 技术。
- [LeminLimez]：创造了 Nugget。
- [0xjonhnnydev]：创造了 [AirLift]。
- [iTechExpert][iTechExpertTwitter]：提供了多项 Springboard/内部选项。
- [Mikasa-san][Mikasa-sanGitHub]：提供了 [Quiet Daemon][QuietDaemonGitHub]。
- 简体中文本地化：本分支维护者（界面、目录、日志与文档）。

[caplayground]: https://caplayground.vercel.app/wallpapers
[i18n]: https://github.com/awesomenull-dev/gNugget-i18n
[NuggetLogo]: https://github.com/GoldenNugget-Team/GoldenNugget-mobile/blob/main/layout/Applications/GoldenNuggetMobile.app/Logo%401x.png
[LeminLimez]: https://github.com/leminlimez
[CowabungaLite]: https://github.com/leminlimez/CowabungaLite
[WallpapersWebsite]: https://cowabun.ga/wallpapers
[AppleDevices]: https://apps.microsoft.com/detail/9np83lwlpz9k
[iTunes]: https://support.apple.com/en-us/106372
[usbmuxdGitHub]: https://github.com/libimobiledevice/usbmuxd
[libimobiledeviceGitHub]: https://github.com/libimobiledevice/libimobiledevice
[ShortcutsApp]: https://apps.apple.com/us/app/shortcuts/id915249334
[MobilegestaltShortcut]: https://www.icloud.com/shortcuts/66bd3c822a0145b98d46cd1c9077e6e5
[ReadMoreGist]: https://gist.github.com/leminlimez/c602c067349140fe979410ef69d39c28
[Wind0ws11Aero]: https://github.com/Wind0ws11Aero
[POEditorJoin]: https://poeditor.com/join/project/UTqpVSE2UD
[JJTechGitHub]: https://github.com/JJTech0130
[TrollStoreGitHub]: https://github.com/JJTech0130/TrollRestore
[PosterRestoreDiscord]: https://discord.gg/gWtzTVhMvh
[dootskyreX]: https://x.com/dootskyre
[MiddoX]: https://x.com/MWRevamped
[dularkGitHub]: https://github.com/dularkian
[SerStarsX]: https://x.com/SerStars_lol
[disfordottieX]: https://x.com/disfordottie
[Mikasa-sanGitHub]: https://github.com/Mikasa-san
[QuietDaemonGitHub]: https://github.com/Mikasa-san/QuietDaemon
[sneakyf1shyGitHub]: https://github.com/f1shy-dev
[lrdsnowGitHub]: https://github.com/Lrdsnow
[EUEnablerGitHub]: https://github.com/Lrdsnow/EUEnabler
[pymobiledevice3GitHub]: https://github.com/doronz88/pymobiledevice3
[PySide6Doc]: https://doc.qt.io/qtforpython-6/
[python-aar-stuffGitHub]: https://github.com/0xilis/python-aar-stuff
[AIEligibilityGist]: https://gist.github.com/f1shy-dev/23b4a78dc283edd30ae2b2e6429129b5
[bl_sbxGitHub]: https://github.com/khanhduytran0/bl_sbx/tree/main
[DuyGitHub]: https://github.com/khanhduytran0
[HuyTwitter]: https://x.com/Little_34306
[iTechExpertTwitter]: https://twitter.com/iTechExpert21
[server]: https://discord.gg/Rm6r4zeE3y
[0xjonhnnydev]: https://github.com/0xjohnnydev
[awesomenull]: https://github.com/awesomenull-dev
[AirLift]: https://github.com/0xjohnnydev/airlift
