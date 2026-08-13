# 架构与对照研究

## 数据路径

```text
OBS / 视频文件
      |
      | RTMP -> SRS/MediaMTX -> HLS，或 FFmpeg -> MJPEG
      v
AVAssetStreamAdapter (mediaserverd)
      |
      | BGRA CVPixelBuffer + IOSurface
      v
VCStreamCoordinator
      |
      | Core Image GPU：按设置旋转/镜像一次
      | 统一方向后的最新源帧供所有输出复用
      v
VCFrameConverter
      |
      | 按网络源帧 + 目标格式缓存转换结果
      | VTPixelTransferSession: 缩放、BGRA -> 原始 420v/420f/BGRA
      v
BWNodeOutput emitSampleBuffer:
      |
      v
系统相机与第三方相机客户端
```

系统模式只在 `mediaserverd` 建立一条网络连接。应用层兼容模式则在每个相机应用内拉流，并代理 `AVCaptureVideoDataOutput`；它还为 `AVCaptureVideoPreviewLayer` 和 `AVCapturePhoto` 提供回退路径。

## 为什么保留真实格式描述

CoreMedia 要求 `CMSampleBuffer` 的格式描述与像素缓冲的宽、高、像素格式和相关附件一致。项目先创建与原始相机像素缓冲完全匹配的目标缓冲，再用 `VTPixelTransferSession` 转换网络帧。如果 `CMVideoFormatDescriptionMatchesImageBuffer` 证明原格式描述与新缓冲完全匹配，则直接复用它以保留色彩、净孔径等扩展；不匹配时才从新缓冲重建描述。不能把 720p BGRA 网络帧直接配上原相机 1080p 420f 的格式描述。

`aspectFill=true` 使用 `kVTScalingMode_Trim`，保持比例并裁切填满；关闭时使用 `kVTScalingMode_Letterbox`。

源方向变换发生在 `VCStreamCoordinator` 接收网络帧时，而不是发生在每个 `BWNodeOutput`。`VCCopyPixelBufferApplyingOrientation` 使用单例 `CIContext`、EXIF 方向语义和可回收 BGRA/IOSurface 池，把 0°/90°/180°/270° 与水平镜像合并为一次 GPU 渲染。旋转后的缓冲成为协调器唯一的最新源帧，因此预览、照片、录像和第三方客户端不会分别重复旋转。方向设置改变时立即清除旧帧和格式缓存；GPU 变换无法创建缓冲时保留未变换源帧，避免相机管线中断。

MJPEG 解码最长边默认 1920，可选 1280、2560 和 3840。提高上限只增加源细节，不会改变真实相机输出的格式描述；最终仍由 `VTPixelTransferSession` 匹配每个目标节点的尺寸和 YUV/BGRA 格式。3840 BGRA 单帧可能超过 30 MB，因此在 A10 上标记为实验性配置。

一个解码帧可能在 `mediaserverd` 内经过多个 `BWNodeOutput`。转换器使用“源像素缓冲指针 + 目标宽高 + 目标像素格式 + 缩放模式 + 原格式描述语义”作为缓存键；指针相同或 `CFEqual` 证明扩展等价时才复用，既避免色彩/净孔径附件不同的节点混用，也避免等价描述对象地址变化造成重复转换。经验证或重建的格式描述与转换缓冲一起缓存，不在每个样本上重复构造。热路径使用固定容量 C 结构数组，不再每帧构造 `NSString` 键或访问 Foundation 字典。

`BWNodeOutput` 在运行时还要通过 `mediaTypeIsVideo` 签名检查，样本必须存在 `CVImageBuffer`，且目标格式必须是明确支持的 YUV/BGRA/ARGB 颜色格式。深度、视差、元数据、音频和压缩输出不进入替换器。

转换器和 MJPEG 解码器的像素池都有分配阈值。每种目标格式最多允许 6 个在途转换缓冲，兼顾相机管线扇出和 A10 内存上限。MJPEG 接收器增量解析 JPEG marker/segment/scan，跳过 APP 段内的嵌入图像，单帧限制为 24 MiB、累计接收缓冲限制为 32 MiB，并对重复损坏日志做 30 秒限频。收到 `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 警告时清理接收状态、转换帧、像素池和 `VTPixelTransferSession`；严重压力时还释放最新网络帧，之后由新帧自动恢复。

协调器为偏好刷新、流连接和方向变换分别维护单调 generation。新的偏好快照只允许最新一次主队列任务生效；帧在方向变换前后各校验一次流与变换 generation，因此旧 URL 的回调、或正在执行旧旋转的 GPU 任务，无法在切换后的清理操作之后重新写入最新帧。

网络回调不会直接在 NSURLSession/HLS 主线程上执行方向渲染。协调器维护一条独立串行帧处理队列和一个受锁保护的待处理槽：GPU 正在处理时到达的新帧会替换槽中的旧帧，处理完立即取最新值。这个 latest-frame-wins 设计把积压上限固定为“一个在处理、一个待处理”，避免 A10 短时过载后继续播放越来越旧的队列。MJPEG 接收器在单次网络回调含有多张完整 JPEG 时同样只解码最后一张完整帧。

系统管线还通过 Darwin notify state 发布“关闭、连接中、接收中、保留最后有效帧、错误”五态。设置面板优先读取这份由 `mediaserverd` 实际接收路径产生的状态，因此检测默认单客户端 MJPEG 时不会抢占第二条连接；仅在系统管线未启用时才建立一个有 8 秒上限的直接 HTTP 数据检测。

FPS 配置范围为 1–240，60 只是 A10/常规相机模式的默认值，不是解码器硬截断。Windows 端必须先确认 OBS Virtual Camera 真实发布相同 DirectShow 模式；高于 64 FPS 时采集队列自动保持至少约半秒、编码后 FIFO 至少约一秒。兼容模式的数据输出仍遵循目标 `AVCapture` 回调的真实节拍，屏幕预览则按设备物理刷新率显示。

`VCStreamCoordinator` 的最新帧、时间和缩放配置由 `os_unfair_lock` 保护。旧像素缓冲在退出临界区后才释放，避免 CoreVideo/IOSurface 析构延长多节点的等待时间。

设备发现和相机能力 API 不做 Hook，因此应用看到的相机名称、位置、焦距能力仍是真实设备。照片只保留真实捕获产生的 TIFF/EXIF/GPS/Apple 信息，并在写出后读回核验；不构造虚假设备身份。兼容模式必须锁定网络源帧，系统模式必须收到 `mediaserverd` 的 receiving/holding 状态后才允许照片重写，插件关闭或 fail-open 时完全走原 API。原场景深度、视差、人物/语义蒙版、HDR 增益图和辅助图不会与另一张网络主图混合。

## 对照的开源项目

### [MurkAskA01/ios-vcam](https://github.com/MurkAskA01/ios-vcam)（原项目）

原实现主要在应用进程中修改 `AVCaptureVideoDataOutput` delegate、覆盖预览层并重写 `AVCapturePhoto` getter。问题包括：全局修改 delegate 类、返回额外 retain 的照片缓冲、设置 key 不一致、宣称 RTSP 但没有 RTSP 解码、仅 arm64、伪造设备能力，以及与相机替换无关的反调试/越狱隐藏 Hook。

### [LiuSky/iOS-vcam](https://github.com/LiuSky/iOS-vcam)

该仓库主要提供 Windows RTMP/HLS 服务、USB 隧道、部署工具和预编译 iOS 包，没有公开 iOS dylib 源码。对其 rootless 包进行结构检查后，可见 dylib 注入 `mediaserverd`，并引用 `CMCapture`、`CMCaptureCore`、`BWNodeOutput`、`VTPixelTransferSession`、H.264/HEVC 和 RTMP 组件。这证明低层相机图与像素转换是覆盖系统管线的关键，但二进制实现不能直接复用或审计。

### [donets2013/MyVcam](https://github.com/donets2013/MyVcam)

该仓库公开了 `mediaserverd` 的 `BWNodeOutput -emitSampleBuffer:` Hook，以及 TCP/WebSocket H.264 + VideoToolbox 解码框架。可复用的方向是单点拉流、IOSurface 缓冲、断线重连和低层注入。其当前代码把网络像素缓冲与原相机格式描述直接组合，可能因尺寸/格式不一致失败；TCP 首次 `read` 也未保证读满固定头，Annex-B 转 AVCC 的长度字节序处理存在风险。因此本项目只采用架构思路，重新实现格式转换和生命周期管理。

### [balayan7988/VCAMBypass](https://github.com/balayan7988/VCAMBypass)

该仓库是针对另一个闭源 VCAM 的授权绕过，不包含相机帧替换实现。它对本项目的功能架构没有可复用价值，也不会纳入任何授权、心跳或绕过逻辑。

## 一手文档约束

- [Theos rootless](https://theos.dev/docs/rootless) scheme 自动添加 `/var/jb` 安装前缀、rootless rpath 和 `iphoneos-arm64` 包架构。
- [Cydia Substrate Darwin deployment](https://www.cydiasubstrate.com/inject/darwin/) 规定每个 dylib 使用独立 filter plist；系统服务用 `Executables=mediaserverd`，应用回退同时要求 UIKit bundle 与 AVFoundation 相机类，避免把带 UIKit 依赖的回退 dylib 注入系统守护进程。
- Apple [TN3121](https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput) 建议尽量保留相机的原生双平面 YUV 像素格式；BGRA 占用更高。因此 BGRA 只作为网络解码中间格式，实际输出转换回原始相机格式。
- [`CMSampleBufferCreateReadyWithImageBuffer`](https://developer.apple.com/documentation/coremedia/cmsamplebuffercreatereadywithimagebuffer%28allocator%3Aimagebuffer%3Aformatdescription%3Asampletiming%3Asamplebufferout%3A%29) 要求格式描述与图像缓冲严格一致。
- [`CMVideoFormatDescriptionMatchesImageBuffer`](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer%28_%3Aimagebuffer%3A%29) 比较尺寸、像素格式和与图像缓冲共用的格式扩展。
- [`VTPixelTransferSessionTransferImage`](https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersessiontransferimage%28_%3Afrom%3Ato%3A%29) 用于复制、缩放和像素格式转换。
- [`CVPixelBufferPool`](https://developer.apple.com/documentation/corevideo/cvpixelbufferpool) 提供可回收像素缓冲和分配阈值，避免系统服务内存无界增长。
- [Responding to low-memory warnings](https://developer.apple.com/documentation/xcode/responding-to-low-memory-warnings) 明确列出了 `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 作为非 UIKit 进程的低内存响应路径。

私有节点信息来自 [iOS 15.2.1 CMCapture 运行时头](https://www.developer.limneos.net/index.php?framework=CMCapture.framework&header=BWNodeOutput.h&ios=15.2.1) 与可公开查看的 [早期 `BWNodeOutput` 头](https://www.developer.limneos.net/index.php?framework=Celestial.framework&header=BWNodeOutput.h&ios=11.1.2)，其中包含 `emitSampleBuffer:`、`mediaTypeIsVideo`、`name`和 `node` 等成员。这些是运行时反射结果，不是 Apple 稳定 API 承诺，所以代码只在签名检查成功后调用。

## 当前边界

`BWNodeOutput` 是私有类，项目运行时查找并最多重试 10 秒，在 Hook 前还会验证方法参数数量、返回类型和样本缓冲指针类型；`mediaTypeIsVideo` 只在返回签名确认为 `BOOL` 时调用。不存在或签名不匹配时不会盲目调用。失败时真实相机保持可用，并可从设置切换到应用层兼容模式。每个 iOS 小版本和目标应用仍需要实机验证。
