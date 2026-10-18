# 简体中文本地化说明

本仓库（`GoldenNugget-mobile-ZH`）是
[GoldenNugget Mobile](https://github.com/GoldenNugget-Team/GoldenNugget-mobile)
的简体中文分支。界面文案采用**源码内直接汉化**：SwiftUI 的 `Text`/`Label`/`Button` 等
字符串字面量直接写成简体中文，不再维护英文 `Localizable.strings`。

## 本地化范围

| 范围 | 文件 |
|---|---|
| 界面 | `Nugget/Views/*.swift` |
| 调整项目录 | `Nugget/Core/TweakCatalog.swift`、`Nugget/Core/TweakCatalogDaemons.swift` |
| 状态栏/预设/跳过设置/墙纸目录 | `Nugget/Core/StatusBarModel.swift`、`GoldenNuggetPresets.swift`、`SkipSetupCatalog.swift`、`WallpaperCatalog.swift` 等 |
| 运行日志与错误提示 | `Nugget/Core/GoldenNuggetEngine.swift`、`TransportFailure.swift`、`PosterBoard*.swift` 等 |
| 应用元数据 | `layout/Applications/GoldenNuggetMobile.app/Info.plist`（开发区域 `zh-Hans`、权限说明、文件类型描述） |
| 文档 | `README.md` |

## 不应翻译的内容

- Swift 标识符、枚举 `rawValue`（持久化/逻辑用）、UserDefaults key、JSON/plist key、URL、文件/设备路径；
- SF Symbol 名称、资源文件名、`bundle` 标识；
- 会被代码比较、解析、脚本正则匹配的字符串（例如 `Prune Manifest.db:`、`AFC media:`、
  `restore verified:`、Rust 日志关键字等），这类日志行保留英文前缀，只翻译其后的说明；
- 模板内容：PosterBoard 的 CA/XML 模板、SQL 语句、base64 资源。

## 校验工具

`scripts/check-localization.py` 以 `git HEAD` 为基准，检查一次改动是否只改变了字符串
**内容**，并保证以下结构不变：

- 字符串字面量数量与顺序；
- 代码骨架（引号外的一切）；
- `\(...)` 插值表达式内部的代码（插值内嵌套字符串的**内容**可以翻译）；
- `%@`/`%d`/`%.1f` 等格式说明符的顺序与数量；
- 变更后的字面量必须包含中文。

```bash
# 检查全部已改动的 Swift 文件，并做语法解析
python3 scripts/check-localization.py --all-changed --parse

# 只检查指定文件
python3 scripts/check-localization.py --files Nugget/Views/TweaksView.swift --parse
```

> 说明：`scripts/check-localization.py` 只做结构门禁；最终能否编译由 CI
> （`.github/workflows/build.yml` / `release.yml`）的 Xcode 构建验证。

## 构建与发布

- 推送到 `main`：`.github/workflows/build.yml` 编译未签名 IPA 并上传为 artifact；
- 手动触发 `Build & Release IPA (中文版)`（`.github/workflows/release.yml`）并填写
  `release_tag`：CI 编译后创建/更新 GitHub Release，附带 `GoldenNuggetMobile.ipa`
  与 `.sha256` 校验文件。

## 已知取舍

- 目录文件 `TweakCatalog.swift` / `TweakCatalogDaemons.swift` 头部标注为生成文件；
  本分支直接汉化了其中的显示用字段。若将来从桌面版重新生成，中文会丢失，需要重新应用翻译。
- 少数开发脚本按英文日志格式解析，因此对应日志仍保留英文前缀（见上）。
