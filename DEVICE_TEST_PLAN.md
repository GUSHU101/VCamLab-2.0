# iPhone 7 Plus 全相机模式真机验收清单

目标设备：iPhone 7 Plus（A10 / arm64）、rootless iOS 15.8.8、ElleKit、PreferenceLoader。每次更换 `.deb` 后保持 SSH 可用，并先确认可以执行 [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) 中的紧急禁用命令。

本清单区分三种结果：

- “颜色帧替换”表示取景、照片主图或视频画面来自网络流。
- “原样透传”表示音频、相机元数据和不支持的颜色格式仍来自真实系统管线；确实使用替换主图的照片不得暴露原物理场景的深度、视差或蒙版。
- “正常使用”表示应用不崩溃、能够开始/结束拍摄、保存并再次打开结果。MJPEG 没有深度信息，因此替换照片应明确没有场景辅助载荷，而不是伪造或错配。

## 安装与基线

- Windows 先进入 `VirtualCamPro-Windows-Control-Center/`，运行 `install-phone.bat --check PHONE_IP`，确认 `/var/jb`、`sudo`、`dpkg` 和 `uid=0(root)` 全部通过。
- 在同一目录运行 `install-phone.bat --setup PHONE_IP`，确认上传大小、包内版本/架构、安装后精确版本均通过，手机 URL 自动写成电脑实际局域网地址，且 `/var/mobile` 中临时 `.deb` 已删除。
- `dpkg -i` 没有依赖或 maintainer-script 错误。
- `/var/jb/Library/MobileSubstrate/DynamicLibraries/` 中存在两套 dylib 和 filter plist。
- 设置中可见 VirtualCamPro，所有开关、URL 与滑块均可保存。
- 将来源设为“网络 HLS / MJPEG”，填写可持续输出的地址，再启用画面替换；随后分别测试屏幕镜像、本地视频和纯 MP3。
- 完全退出相机相关应用后重新打开。
- 日志出现 `mediaserverd BWNodeOutput hooks installed` 且 class 数量至少为 1；收到来源后只记录一次 `SpringBoard published first shared frame`，且尺寸符合来源与旋转设置。
- 同时运行两个独立 CaptureSession（优先 Camera + Safari/WebKit `getUserMedia`）：反复启动/停止其中一个 50 次，另一个必须持续显示替换帧。任何单一节点成功都不得导致另一路真实帧穿透；这项专门验证逐样本证据替代全局 heartbeat 门控。
- 关闭画面替换时，以下所有模式必须保持真实相机原有行为，作为对照基线。
- 网络源使用带方向标记和左右文字的画面，在手机上改变本地旋转/镜像/FPS/质量设置，网络输出必须完全不变；方向只能随 OBS/Windows 端调整。
- 本地文件依次验证 0°、90°、180°、270°、水平镜像、1280/1920/2560/3840 质量和 FPS 上限；设置改变后旧方向帧必须立即消失。
- 依次验证网络 15、24、25、29.97、30、59.94、60 FPS；手机本地 FPS 滑块不得改变收到的网络节奏。若 OBS Virtual Camera 实际发布对应模式，再验证 120/240 FPS。
- 在同一手机目录放置至少三段按名称可排序的视频：音量加切到下一段、音量减切到上一段、长按不得快速连跳；切回网络来源后音量键必须恢复系统音量行为。
- 修改并保存当前 OBS Profile 的画布/FPS 后直接启动脚本，确认自动读取保存值；Virtual Camera 仍为旧模式时必须明确报告保存值与活动值不一致。
- 保持 OBS 运行并启用带身份验证的 WebSocket 服务器，分别停止 Virtual Camera、修改保存分辨率/FPS；启动器必须自动启动或只刷新 Virtual Camera，OBS 进程和未保存场景不得被关闭。
- SpringBoard 收到首帧后在设置点“检测当前网络流”，应直接显示媒体服务正在接收，不得抢占单客户端 MJPEG；断开 Windows 桥接后应显示重连状态。

## 统一系统管线：照片

| 模式 | 操作 | 必须通过的结果 |
| --- | --- | --- |
| 后置 1× | 竖屏、横屏各拍一张 | 预览和保存主图均为网络画面；尺寸、方向正确 |
| 后置 2× | 切到长焦后拍照 | 不崩溃；保存主图仍为网络画面；设备镜头能力不被改写 |
| 前置 | 切换前摄并拍照 | 无黑屏、绿屏或方向错误；保存主图为网络画面 |
| 闪光灯/HDR | 分别使用自动、开、关 | 拍摄和保存完成；闪光灯硬件行为不影响替换主图 |
| Live Photo | 开启 Live Photo 后拍摄并长按回放 | 静态主图和短视频颜色帧均被替换；音频原样保留 |
| 连拍 | 使用音量键或快门手势连拍 | 连拍过程不崩溃，每张可保存并打开 |
| 人像 | 使用后置人像模式拍摄 | 颜色主图被替换且照片可保存；`depthData`、人物效果蒙版和语义蒙版不返回原场景数据 |
| 全景 | 完成一次水平全景扫描 | 取帧和保存链路不崩溃，输出颜色内容来自网络流；拼接结果需人工确认 |

检查照片信息时应满足：插件不创建虚假的相机名称、镜头型号或设备型号。保存的 EXIF 若存在，仍可能由真实 iPhone 管线产生；这是保留系统拍照链路的预期结果。

## 统一系统管线：视频与音频

| 模式 | 操作 | 必须通过的结果 |
| --- | --- | --- |
| 720p/1080p | 各录制至少 30 秒 | 预览和成片均为网络画面，时间轴连续，音频正常 |
| 1080p60 | 录制至少 30 秒 | 成片可播放；网络源帧率不足时允许重复最新帧，但不得损坏时间戳 |
| 4K30 | 后摄录制至少 30 秒 | 能开始、结束并保存；A10 温度和内存不持续失控 |
| 前置录像 | 录制并切换横竖屏方向 | 画面方向正确，音频原样保留 |
| 慢动作 | 120 fps 与 240 fps 各录制一次 | 录制与慢放可完成；网络帧会按原相机时间戳重复，不承诺生成新的高帧率运动细节 |
| 延时摄影 | 连续录制至少 2 分钟 | 录制可停止和保存，成片为网络画面 |

网络和屏幕来源不应发布共享音频，即使发送文件带音轨也必须保留手机原生麦克风 `CMSampleBuffer`。本地视频带音轨时验证麦克风输出为文件音频；纯 MP3 时验证画面仍为物理摄像头。未知音频/颜色格式必须回退真实样本。

## 第三方应用与浏览器

- 至少一个使用 `AVCaptureVideoDataOutput` 的第三方应用：预览和回调均收到替换颜色帧。
- 至少一个使用 `AVCaptureMovieFileOutput` 的录像应用：成片收到系统媒体图替换颜色帧。
- FaceTime 或一个测试视频通话应用：本地预览和对端画面均验证；麦克风音频保持正常。
- Safari 网页 `getUserMedia`：前后摄各验证一次；网页获得替换画面，授权流程保持系统原样。
- 应用和网页仍枚举系统前/后摄，不要求出现名为 OBS 的新设备；分别验证系统心跳存在和强制停止 `mediaserverd` 后的 WebKit 自动回退。
- 二维码/条码扫描应用：确认扫描器分析的是预期画面；系统媒体图的颜色帧替换会改变识别结果。

## 应用层自动回退

不再提供手动模式。系统 Hook 只有实际成功输出替换样本才发布 1.5 秒心跳；停止/禁用系统 Hook 后，标准 AVFoundation 应用应自动接管。

- `AVCaptureVideoDataOutput` delegate 在网络首帧尚未到达时也必须安装；到帧前透传真实画面，到帧后自动开始替换。
- 运行期间关闭替换后，已安装的 delegate proxy 只透传原始帧；再次启用后无需重新创建 capture session 即可恢复替换。
- `AVCaptureVideoPreviewLayer` 在未启用时以低频率隐藏等待，启用后自动显示网络帧。
- `AVCapturePhoto` 的 full-resolution、preview、CGImage 和 file-data 路径尺寸一致，不能复用错误尺寸或像素格式的缓存。
- JPEG/HEIF 重写应保留并读回核验真实 TIFF/EXIF/GPS/Apple 信息和替换尺寸，同时只保存替换主图；不得复制原场景的额外图像、深度/视差、人像/语义蒙版或 HDR 增益图，也不得使用无元数据 UIKit JPEG。验证失败时必须返回真实原相机文件。
- 插件关闭、尚无网络帧或系统管线未报告接收/保持替换帧时，`fileDataRepresentation` 必须直接走原 API，不得触发任何重编码。
- 应用回退不是 `AVCaptureMovieFileOutput` 和 `AVCaptureMetadataOutput` 的完整替代路径；录像、扫码和系统相机全部模式必须以低层系统 Hook 结果为验收标准。

## 切换、断流和压力测试

- 连续切换前摄、后摄 1×、后摄 2×、照片和录像各 20 次，无崩溃或持续内存增长。
- OBS 媒体源连续执行暂停、继续、重新开始和场景切换各 20 次，手机不得断开；暂停期间应持续显示稳定静止帧。
- 竖屏、左横屏、右横屏各保持预览并拍照/录像，裁切设置分别验证“填充”和“适应”。
- 默认“保持最后一帧”时停止 FFmpeg：画面静止；恢复推流后自动继续。
- 关闭“保持最后一帧”并将旧帧超时设为 2 秒：断流约 2 秒后恢复真实相机，推流恢复后重新替换。
- 提供只建立 HTTP 连接但不发送 JPEG 的端点：约 15 秒出现首帧超时日志并重连。
- 切换流 URL 后不得再次出现上一个 URL 的画面。
- 连续预览 15 分钟并同时运行高内存应用；出现 `Released conversion caches` 后下一网络帧应自动恢复，`mediaserverd` 不得进入崩溃循环。
- 同时打开多个视频输出节点连续运行 60 分钟，记录 `mediaserverd` 与目标应用的 footprint/IOSurface 数量；预热后应围绕固定池上下波动，不能随 cache race 次数单调增长。结束所有 CaptureSession 后再次采样，确认 wrapper lease 已回收。
- 在 1080p60 下短时制造 Wi-Fi 抖动或 JPEG 解码压力；接收线程不得被 ImageIO 解码阻塞，恢复后必须在短队列范围内追上最新帧，不能继续播放秒级旧 FIFO。
- 收集 `Slow pixel transfer` 日志中的 `wait/transfer/total`：1080p60 的持续 `total` 不应反复超过 16.67 ms；如果 `wait` 明显高于 `transfer`，优先检查多节点争用，如果 `transfer` 本身超预算，则记录具体尺寸/像素格式并降低真机验收目标，不能仅凭源码支持项宣称 4K/120/240 FPS 已达标。

## 保留诊断证据

```bash
log show --last 15m --style compact \
  --predicate 'process == "mediaserverd" OR eventMessage CONTAINS "VirtualCamPro"'

ls -lt /var/mobile/Library/Logs/CrashReporter/ | head -20
```

每个失败项目记录：模式、前/后摄或 1×/2×、横竖屏、目标分辨率/帧率、源协议、源分辨率、首个转换失败日志、同时存在的 CaptureSession 数量、运行前后 footprint/IOSurface 变化，以及是否生成可打开的照片或视频。仅凭 CI 编译通过不能证明 iOS 15.8.8 的私有 CMCapture 图与假设一致，也不能替代这份真机验收。
