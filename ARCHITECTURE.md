# 统一系统管线架构

## 目标

本项目替换的是系统相机媒体图里的真实样本，不是预览覆盖层。主路径位于 `mediaserverd` 的 `CMCapture`/`BWGraph` 输出边界：所有可识别的颜色 `CVImageBuffer` 与线性 PCM 麦克风样本在进入照片、录像、视频通话、WebRTC、扫码等下游消费者前被替换。

`BWNodeOutput -emitSampleBuffer:` 是 iOS 15 上兼顾“足够靠近系统相机源”和“仍然有稳定格式描述”的边界。继续向物理传感器/ISP 前端下移会遇到 Bayer RAW、同步脉冲、镜头标定和厂商私有元数据；把普通 BGRA/YUV 帧塞到这些入口会破坏 ISP 图，反而更容易导致 Camera、FaceTime 或 `mediaserverd` 崩溃。因此项目不会为了名义上的“更底层”盲目 Hook 原始传感器节点。

| 层级 | 本项目行为 | 结果 |
| --- | --- | --- |
| L0 CMOS/Lens/ISP | 不修改硬件；原颜色内容在 L2 被丢弃 | 保留对焦、曝光、镜头与 ISP 稳定性 |
| L1 驱动/Kernel/IOKit | 不写内核驱动、不伪造硬件设备 | 不改变设备树、电源与相机驱动协议 |
| L2 Camera Service | Hook `mediaserverd` 中基类及直接覆写的 `BWNodeOutput` | 在系统扇出前替换颜色和可支持的 PCM 样本 |
| L3 AVFoundation Capture | 保留真实 Device/Session/Input/Connection 对象 | 应用能力查询和会话状态正常，内容来自 L2 替换样本 |
| L4 CoreMedia/CoreVideo | 重建匹配的 CMSampleBuffer/CVPixelBuffer/ASBD/timing | 下游处理的是实际替换数据，不是 UI 贴图 |
| L5 输出分支 | 系统路径覆盖 Photo/Movie/DataOutput/Preview；标准 AVFoundation 自动回退 | 拍照、录像、通话、WebRTC、扫码尽量一致 |

L0/L1 若要出现“虚拟画面”，必须开发可被 Apple 相机栈接受的内核虚拟传感器/驱动并重建 ISP 私有协议；这不属于 MobileSubstrate dylib 能安全完成的范围。当前设计的承诺是 L2–L5 真替换，L0/L1 只作为相机时钟、格式模板和硬件能力来源。

## 进程与数据路径

```text
                         SpringBoard（唯一生产者）
        ┌──────────────────────┼───────────────────────┐
        │                      │                       │
   网络 HLS/MJPEG       CoreAnimation 屏幕       本地 MP4/MOV/MP3
        │                      │                       │
   上游参数原样解码       显示方向原样输出        本地限帧/缩放/旋转/镜像
        │                      │                       │
        └──────────> BGRA 全局 IOSurface <────────────┘
                               │
                         3 槽 Surface 环
                               │ Darwin notify:
                               │ generation + IOSurfaceID
                               v
             mediaserverd（零拷贝映射，同一物理页）
                               │
          BWNodeOutput -emitSampleBuffer: 运行时签名校验
                 ┌─────────────┴──────────────┐
                 │                            │
       颜色 CVImageBuffer              线性 PCM 音频
       匹配原宽高/格式/附件             匹配原 ASBD/样本数/PTS
                 │                            │
                 └─────────────┬──────────────┘
                               v
        Camera / Photo / Movie / FaceTime / WebRTC / 扫码

        当前样本无系统替换证据 ──> 该样本执行 AVFoundation fallback
```

SpringBoard 实例负责 `AVAssetStreamAdapter`、`VCScreenCaptureSource` 或 `VCLocalMediaSource`。`mediaserverd` 和每个应用都只运行 `VCSharedVideoClient`/`VCSharedAudioClient`，不建立网络连接、不重复解码媒体。

来源策略是明确隔离的：网络 MJPEG/HLS 不读取手机端的 FPS、质量、旋转、镜像和最长边设置，MJPEG 按发送端完整像素尺寸解码；屏幕来源按系统显示方向和固定刷新节奏输出；只有本地文件进入设备端解码尺寸、最高 FPS、比例、旋转和镜像处理。网络/屏幕来源不向共享音频环写数据，因此真实麦克风保持原样。

## 视频零拷贝

生产者要求所有输出缓冲带 `kCVPixelBufferIOSurfacePropertiesKey` 与 `kIOSurfaceIsGlobal`。发布时只做三件事：

1. 在 3 槽环中 retain 当前 `CVPixelBuffer`，让消费者跨帧调度时仍能 lookup。
2. 首次建立时通过 Darwin notify state 发布一块常驻控制 IOSurface 的 ID；每个进程长期复用固定注册 token，并只用 `notify_check` 侦测控制块建立或失效事件。
3. 每帧只在控制 IOSurface 中以 C11 release/acquire 原子顺序写入 32 位 generation + 32 位数据 `IOSurfaceID` 以及 `mach_continuous_time` 毫秒时间戳。正常媒体热路径不再逐帧执行 `notify_get_state`、`notify_set_state` 或 `notify_post`。音频的新鲜度时间戳同样位于 PCM 环头部，Surface 通知只在环建立/失效时更新。

消费者调用 `IOSurfaceLookup`，再用 `CVPixelBufferCreateWithIOSurface` 包装同一 Surface。该步骤只创建 CoreVideo 包装对象，不复制像素。返回给调用方的每个 wrapper 都拥有一个明确的 `IOSurfaceIncrementUseCount` lease，并且只能用 `VCReleaseSharedVideoPixelBuffer` 对称归还。并发线程争用同一缓存项时，代码先给缓存胜者增加自己的 lease，再归还落败 wrapper 的 lease，不依赖隐式所有权转移。包装对象按完整的 `generation + IOSurfaceID` 控制字缓存：同一帧经过多个相机输出节点时复用同一指针，从而命中像素转换缓存；同一 Surface 槽被新 generation 复用时一定创建新包装，不能误用上一轮转换结果。控制字在 lookup 前后不一致时最多重试三次。

源缓冲如果没有 IOSurface 会直接丢弃并保留真实相机，而不是退化成未限制的 CPU 拷贝。HLS、MJPEG、本地视频、屏幕捕获和本地方向变换的池都显式创建全局 IOSurface。

## 音频共享与 MP3 麦克风

本地媒体只在 SpringBoard 解码为 48 kHz、双声道、交错 Float32。PCM 写入一块三秒容量的全局 IOSurface 环，头部使用 C11 release/acquire 原子计数；进程间不传输 `NSData` 或归档对象。

`mediaserverd` 收到真实麦克风样本时，以它的 `AudioStreamBasicDescription`、样本数和 PTS 为模板：

- 支持常见 16/24/32 位有符号整数与 32/64 位浮点 LPCM；
- 支持单声道/双声道、交错/非交错与 8–192 kHz；
- 对源 PCM 做线性重采样，单声道使用左右平均；
- 每个 `BWNodeOutput`/应用音频输出持有独立环形缓冲游标，新 consumer 在实时边缘后保留约 30 ms 抗抖储备，多 Session 不会竞争同一个读位置；
- 重采样上下文跨回调保留小数相位与前视样本，只消费已经越过的完整 48 kHz 帧，不在每个 callback 重新起相或丢弃插值尾部；
- 保留原样本附件与呈现时间戳；
- 压缩或未知格式直接返回原麦克风样本。

纯音频文件不发布视频 Surface，因此视频路径自然 fail-open 到物理摄像头，实现“MP3 走麦克风 + 本地摄像头画面”。

## 系统媒体图替换

Hook 安装前先枚举 `BWNodeOutput` 基类以及所有直接覆写 `emitSampleBuffer:` 的子类，避免专用照片/录像输出类绕过基类实现。运行时类到原始 IMP 的解析结果进入 128 槽无锁正向缓存，正常帧不再为每个样本扫描继承链和最多 64 个 Hook；dyld 后续发现并 Hook 新子类时会覆盖该类的缓存项。已替换样本带可传播的 sample/pixel-buffer attachment：同一系统图中的后续 Hook 看到标记后直接放行，应用层也能把“这个具体样本已替换”作为旁路证据；若中间私有节点丢弃未知 attachment，应用层会保守地再次执行 fallback，而不会泄露真实帧。每个候选类还要检查：

- `BWNodeOutput` 类和 `emitSampleBuffer:` 存在；
- 参数数量为 3，返回值为 `void`，第三个参数为指针；
- `mediaTypeIsVideo`/`mediaTypeIsAudio` 只有在返回签名确认为 `BOOL` 时才调用；
- 类尚未加载时由 dyld 回调触发，并最多重试 10 秒。

每个样本按内容再次分类：

- 存在 `CVImageBuffer`、节点声明为视频、像素格式属于明确支持的 BGRA/ARGB/双平面 YUV 时进入视频转换；
- 存在线性 PCM ASBD 且节点声明为音频时进入音频转换；
- 深度、视差、元数据、压缩辅助流与未知格式原样透传。

视频由 `VTPixelTransferSession` 转成真实相机节点要求的宽、高、像素格式和缩放方式。只有 `CMVideoFormatDescriptionMatchesImageBuffer` 成功时才复用原描述，否则从新缓冲创建匹配描述。原样本 timing 与可传播 attachments 会复制到替换样本。

转换器按来源代次、目标宽高、像素格式、缩放方式和格式描述语义复用结果；它保留多个最近来源代次，使下一帧已经到达时，上一帧的其他输出节点仍能命中。固定容量池限制每种格式最多 6 个在途缓冲，转换缓存采用 LRU 并设置 64 MiB 总硬上限，避免 A10 上的 4K 扇出分配失控。池/缓存状态锁与 `VTPixelTransferSession` 串行 lane 已拆开：缓存命中和池操作不等待另一节点的 GPU 转换；若 lane 正忙，相同目标会复用最近完整转换帧，以当前相机样本 timing 继续输出，而不是阻塞 `emitSampleBuffer:` 或回退真实帧。冷启动尚无可复用帧时才等待 lane，获得后仍会二次查缓存。PixelTransfer 本身仍是同步调用，4K、高帧率和多输出能力必须以 A10 真机测量为准。

## 自动回退而不是手动模式

系统 Hook 只有在替换样本成功交给原 `emitSampleBuffer:` 后才更新视频或音频健康状态；全局状态最多 4 Hz，仅供诊断，绝不作为 fallback 正确性条件。应用 Hook 的规则是：

- 当前 `CMSampleBuffer` 带系统替换 attachment：只旁路这个具体样本；
- 当前样本没有证据但共享媒体有效：代理 `AVCaptureVideoDataOutput` 或 `AVCaptureAudioDataOutput`；
- 预览层使用共享 IOSurface contents，不受其他 session 的系统健康状态影响；
- 照片回退锁定同一源帧，保留并读回核验真实 TIFF/EXIF/GPS/Apple 元数据；
- 任何转换、编码或元数据核验失败：调用原 API/返回原文件。

这套协商不需要设置开关，也不会再出现 Session A 的成功心跳全局关闭 Session B fallback。私有系统节点在某个 iOS 小版本不存在时，目标应用只要使用标准 AVFoundation 数据输出/照片接口就会自动接管；`AVCaptureMovieFileOutput` 等无法由公开应用接口完整替代的路径仍依赖系统 Hook。

## 来源生命周期

偏好刷新、来源切换和方向变换分别维护 generation。旧 URL、本地 reader、正在执行的 GPU 任务以及异步错误/完成回调在发布前重新检查 generation，不能越过一次来源切换写回旧帧或覆盖新来源状态。

帧处理采用 latest-frame-wins：一帧处理中只保留一个待处理槽，新帧覆盖旧待处理帧。网络突发或 A10 GPU 短暂繁忙不会形成延迟不断增长的队列。

MJPEG 的 URLSession 回调只做增量边界解析并更新一个“最新完整 JPEG”槽，实际 VideoToolbox/ImageIO 解码位于独立的高优先级串行队列；解码期间到达的旧帧被新帧覆盖，网络 socket 不等待像素解码。硬件 JPEG 会话的瞬时失败只触发 30 秒 ImageIO 冷却，随后自动探测恢复，不会永久锁死 CPU 路径。HLS 的 `AVPlayerItemVideoOutput` 轮询按轨道 nominal FPS 的两倍动态限制在 30–240 Hz。屏幕来源把 UIKit 几何读取异步合并为约 4 Hz，采集队列不再逐帧同步等待 SpringBoard 主线程。本地文件按媒体 PTS 节奏读取，超过两个目标帧间隔的旧视频帧直接丢弃，音频仍连续推进，避免解码抖动演变成持续音画延迟。

本地文件路径同时定义一个目录播放列表：SpringBoard 只枚举同目录内受支持的视频扩展名并自然排序。`SBVolumeControl` 的方法签名在运行时确认为无参数 `void` 后才安装音量键 Hook；音量加选择下一项、音量减选择上一项，并用 350 ms 防抖抑制长按重复。非本地来源、无可切换项目或私有方法不匹配时完整调用原音量实现。非循环文件自然到达 EOF 时单独发布完成状态并立即失效共享音频环，视频是否继续保持最后一帧仍由断流策略决定；显式停止或切换来源不伪报完成。

内存压力时清理 VideoToolbox 会话、转换缓存与多余 Surface；严重压力释放音频环。生产者的下一帧会自动重建。停用或切换来源时先停止回调、增加 generation，再清空视频/音频通知，消费者立刻恢复真实相机和麦克风。设置页的“重载当前来源”只写入一个不透明 restart generation，使同一 URL/文件也执行这套原子重建，不改任何画面参数。控制面板以原生 PreferenceLoader 行启动，只读轮询在页面完全出现后才开始，长期持有四个 Darwin notify token，并在单次刷新周期内合并偏好同步；私有行重载异常时自动停表并保留静态设置。屏幕几何查询即使暂时失败也只按约 4 Hz 重试，不把 60 FPS 采集回调放大为主线程任务风暴。

## 身份与元数据边界

项目不 Hook `AVCaptureDevice` 发现和能力 API，不改 bundle/process/签名身份，也不伪造 Apple 系统组件、相机名称、镜头、设备型号或 EXIF。系统集成依靠精确的进程过滤和运行时能力探测，不依靠身份伪装。

照片中的深度、视差、人物/语义蒙版、HDR 增益图和辅助图属于物理场景。替换主图没有可信重建数据时会抑制这些不匹配载荷，避免生成内部矛盾的照片文件。

## 仍需实机确认的私有边界

`BWNodeOutput` 和 `CARenderServerRenderDisplay` 都不是 Apple 稳定 API。代码针对 iOS 15.x 运行时检查并 fail-open，但以下内容必须在每个目标小版本实机验收：系统 Camera 全模式、FaceTime、第三方录像、WebKit `getUserMedia`、扫码、前后台切换、来电中断、横竖屏、内存压力和 SpringBoard/`mediaserverd` 重启。

参考：

- [Theos rootless](https://theos.dev/docs/rootless)
- [Cydia Substrate Darwin deployment](https://www.cydiasubstrate.com/inject/darwin/)
- [Apple TN3121：选择相机输出像素格式](https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput)
- [Apple CoreMedia：可传播 attachment](https://developer.apple.com/documentation/coremedia/kcmattachmentmode_shouldpropagate)
- [Apple VideoToolbox：VTPixelTransferSessionTransferImage](https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersessiontransferimage(_:from:to:))
- [Apple Darwin notify：notify_register_check](https://developer.apple.com/documentation/darwinnotify/notify_register_check(_:_:))
- [MurkAskA01/ios-vcam](https://github.com/MurkAskA01/ios-vcam)
- [donets2013/MyVcam](https://github.com/donets2013/MyVcam)
