# 光谱暗房 · Spectral Darkroom for iPhone

<img src="ios/SpectralDarkroom/Icon/AppIcon-1024.png" width="120" alt="光谱暗房应用图标">

**把手机照片带进数字暗房，选择胶片和相纸，预览冲印效果，再导出照片。**

Spectral Darkroom 是面向 iPhone 的胶片与相纸模拟应用原型。它使用 SpektraLab 的 C++/Metal 胶片渲染引擎和为手机重新编写的 SwiftUI 暗房界面。

**使用流程：** 从系统照片选择器导入图片 → 选择胶片与相纸 → 调整曝光、颗粒并预览 → 导出 Display P3 JPEG 到系统相册。反转片采用直接扫描；应用内可回看和分享导出记录。

当前源码版本为 **0.2.6（构建号 8）**，包含 25 种胶片、9 种相纸。材料卡片使用随应用提供的示例预览图，支持搜索、分类、排序和拖动自定义顺序；不兼容当前负片的相纸会置灰。微调面板增加了光晕、胶片曲线、场景宽容度和黑白相纸等级等选项。导入照片后的主画面由渲染引擎根据所选材料和参数生成预览。

简体中文主屏幕名称为 **光谱暗房**，其他语言环境使用 **Darkroom**。图标源文件位于 [`ios/SpectralDarkroom/Icon/AppIcon-1024.png`](ios/SpectralDarkroom/Icon/AppIcon-1024.png)，可编辑的 Core Graphics 绘制代码位于 [`ios/Tools/make-app-icon.swift`](ios/Tools/make-app-icon.swift)。

**This is an unofficial experimental iPhone port**, not the complete SpektraLab desktop app or an official iOS release. The current build is a prototype; actual rendering and installation still need device validation.

## 应用画面

以下为早期版本在 iPhone 18 Pro 模拟器中的实际截图，展示导入照片、选择胶片与相纸、调整参数和查看导出记录。0.2.6 的材料列表与微调界面已扩展，截图尚未更新：

| ① 导入照片 | ② 胶片预览 |
|:---:|:---:|
| <img src="docs/screenshots/01-import.png" width="260" alt="导入照片的应用首屏"> | <img src="docs/screenshots/02-film.png" width="260" alt="Earthrise 照片的胶片冲印预览"> |
| **③ 选择相纸**<br><img src="docs/screenshots/03-paper.png" width="260" alt="选择相纸"> | **④ 调整参数**<br><img src="docs/screenshots/04-adjust.png" width="260" alt="调整曝光与颗粒"> |

<p align="center">
  <strong>⑤ 导出记录</strong><br>
  <img src="docs/screenshots/05-history.png" width="260" alt="导出记录">
</p>

演示照片是 NASA 阿波罗 8 号拍摄的 [Earthrise](https://science.nasa.gov/resource/image-earthrise/)（AS08-14-2383）；[苹果 App Store 的官方编辑文章](https://apps.apple.com/id/iphone/story/id1480183734)也曾介绍这张照片。照片来自 NASA，截图不代表 Apple 或 NASA 对本项目的认可。NASA 的[媒体使用说明](https://www.nasa.gov/nasa-brand-center/images-and-media/)适用于该照片；本仓库只包含应用截图，不分发苹果 Landmarks 示例包的照片。

## 下载 IPA

[下载 SpectralDarkroom-unsigned.ipa](https://raw.githubusercontent.com/IsBEICHEN/SpectralDarkroom-iOS/main/downloads/SpectralDarkroom-unsigned.ipa)（0.2.6，约 11.6 MB；iOS 18+、arm64 iPhone）

当前 IPA 的 SHA-256：`aa6bd69e64c0942bfd8bef2b6d39873579eab1ad34ba1575fad8df85c9572786`。下载后可运行 `shasum -a 256 SpectralDarkroom-unsigned.ipa` 核对文件。

这是由本仓库源码生成的 **ad-hoc 签名包**，用于检查构建结果，**不能直接安装到 iPhone**。安装前须使用自己的 Apple 开发团队及适当的描述文件重新签名；本仓库不提供开发证书、私钥或描述文件。需要自行构建时使用下面的脚本。

## 原项目与来源

- 直接移植来源：[JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab)，由 Hanze Qiu 开发的 macOS 胶片与相纸模拟器。本项目复用了其中的 C++/Metal 渲染引擎及部分资源，并重新编写了适用于 iPhone 的 SwiftUI 界面和构建脚本。
- 更早的胶片过程模型、胶片与相纸配置及印相 LUT 来源：[andreavolpato/spektrafilm](https://github.com/andreavolpato/spektrafilm)，作者 Andrea Volpato。SpektraLab 本身基于该项目进行原生 C++/Metal 移植。

感谢两位原作者及相关贡献者。本仓库与上述项目没有官方关联；名称 **Spectral Darkroom** 用于区分该 iPhone 原型与 SpektraLab 桌面产品。

## 当前范围

- iOS 18 及以上，面向 arm64 iPhone。
- 从系统照片选择器导入 JPEG、HEIC 或系统支持的 RAW；选择 25 种胶片和 9 种相纸，调整曝光、印相曝光、颗粒等参数，预览效果，导出 Display P3 JPEG 到系统相册，并在应用内保留导出记录以便回看和分享。
- 导入图片的长边目前限制为 4096 像素。尚未覆盖桌面版的完整编辑流程和色彩管理选项。早期版本的模拟器预览已运行；0.2.6 的真机渲染结果仍需验证。

## 技术实现

1. **照片输入：** PhotosUI 选择照片；Core Image 解码并处理方向，将图像转换为线性 sRGB 浮点 RGBA 像素后交给引擎。长边超过 4096 像素时先缩小。
2. **胶片冲印：** Swift 通过 C 接口调用 SpektraLab 的 C++20 引擎。引擎使用 Metal 渲染、胶片与相纸配置以及印相 LUT；界面将材料及各项微调设置传入冲印会话。材料目录由打包的配置生成，黑白相纸等级和兼容性依据随应用提供的滤色数据。
3. **预览与导出：** 渲染结果转换为 Display P3 图像，编码成 JPEG，使用 Photos 框架保存到系统相册，并在应用支持目录保留导出副本供历史列表回看、分享。SwiftUI 提供 iPhone 编辑界面；iOS 26 及以上采用系统 glass 导航样式，较低版本使用材质背景。
4. **构建与打包：** `ios/build-iphone.sh` 使用 iPhoneOS SDK 的 `clang++` 编译 C++/Metal 引擎并打包静态库，以 `actool` 编译应用图标，再用 `swiftc` 链接 Swift 应用和系统框架，合并材料配置、生成目录并复制示例卡片与许可文件，ad-hoc 签名后压缩为 IPA。缺少 Xcode Metal Toolchain 时会携带 MSL 源码供运行时编译；此路径仍需真机验证。

## 从源码构建

在安装了 Xcode 和 iOS SDK 的 Apple 芯片 Mac 上运行：

```sh
./ios/build-iphone.sh /path/to/output-directory
```

脚本生成 `SpectralDarkroom-unsigned.ipa`。构建细节见 [ios/README.md](ios/README.md)。

本仓库公开源码、构建所需资源和上述未用于安装的 IPA，不包含开发证书、描述文件或私人会话记录。

## 许可与致谢

- 应用及 C++/Metal 引擎：[GPL-3.0-or-later](LICENSE.txt)。
- 胶片与相纸配置、印相 LUT：来自 `spektrafilm`，采用 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。
- Apple `metal-cpp` 头文件：[Apache-2.0](engine/third_party/metal-cpp/LICENSE.txt)。

详细来源及限制见 [iOS 应用声明](ios/SpectralDarkroom/NOTICE.md) 和原项目的许可说明。SpektraLab 的名称与图标不包含在上述代码和数据许可中；本项目不使用其应用图标。
