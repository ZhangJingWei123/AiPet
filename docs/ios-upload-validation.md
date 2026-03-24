# iOS 上传校验失败（缺少图标）修复记录

## 原始问题

在 Xcode 执行 Archive/Distribute 上传到 App Store Connect 时，出现校验失败：

- 缺少 iPhone/iPod Touch `120x120` PNG 图标
- 缺少 iPad `152x152` PNG 图标

## 根因

工程设置指定了 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，但项目内缺少 `Assets.xcassets/AppIcon.appiconset` 以及对应尺寸的图标资源，因此上传校验阶段判定包内缺少必需图标。

## 修复方案

1. 新增资源目录：`AIPetApp/Assets.xcassets/AppIcon.appiconset`
2. 补齐标准 AppIcon 尺寸清单（包含 iPhone 120x120、iPad 152x152 以及 App Store 1024x1024）
3. 将 `Assets.xcassets` 加入 Xcode 工程并添加到 `Resources` build phase
4. 在自动生成 Info.plist 模式下，显式设置 `INFOPLIST_KEY_CFBundleIconName = AppIcon`

## 验证方式与结果

使用 iPhoneOS Release 构建并开启 store 校验（禁用签名，仅用于本地验证资源与产物）：

```bash
xcodebuild -project AIPetApp/AIPetApp.xcodeproj \
  -scheme AIPetApp \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath ./.DerivedDataAIPetDevice \
  clean build CODE_SIGNING_ALLOWED=NO
```

结果：`BUILD SUCCEEDED`，并且产物 `.app` 内存在：

- `AppIcon60x60@2x.png`（120x120）
- `AppIcon76x76@2x~ipad.png`（152x152）
- `Assets.car`

