# VirtualCamPro

VirtualCamPro 是面向 **rootless 越狱 iOS 15** 的网络流相机画面替换插件。默认引擎注入 `mediaserverd` 的相机图输出节点，使系统相机和第三方 `AVCaptureSession` 客户端接收到替换后的像素帧，而不只是给预览界面覆盖一层图片。

当前版本：`2.8.0`

## 功能

- 系统管线模式：在 `mediaserverd` 的 `BWNodeOutput` 视频输出处替换帧。
- 应用层兼容模式：始终安装可动态启停的 `AVCaptureVideoDataOutput` delegate 代理，并替换预览和 `AVCapturePhoto` 结果；照片优先保留原容器和真实设备 TIFF/EXIF/GPS/Apple 元数据，写出后还会读回核验。网络图没有可信深度时不会混入原场景的深度、视差、人物/语义蒙版或辅助图。
- 模式覆盖：默认系统管线统一处理普通照片、Live Photo、连拍、人像主图、全景取帧、普通录像、慢动作、延时摄影、视频通话和浏览器相机的颜色帧；音频、深度、视差和元数据流不被当作颜色帧改写。
- HLS：URL 中包含 `.m3u8` 时使用 `AVPlayerItemVideoOutput` 解码。
- MJPEG：其他 HTTP/HTTPS URL 按连续 JPEG 流解析；增量校验 JPEG 段结构并限制单帧与接收缓冲，损坏输入不会无界占用 `mediaserverd` 内存。
- VideoToolbox 像素转换：输出尺寸、像素格式和时间戳跟随真实相机原始帧。
- 转换结果缓存：同一网络帧经过多个相机图节点时复用已转换的像素缓冲，降低 A10 负载。
- 节点与格式隔离：仅处理声明为视频的颜色像素输出，深度、视差、音频和压缩样本原样透传。
- 内存压力恢复：iOS 警告或严重内存压力时释放转换帧、像素池和 VideoToolbox 会话，下一帧自动重建。
- 自动重连与看门狗：首帧或后续帧超时时主动重建连接，退避最长 30 秒。
- 最新帧优先：网络突发或 GPU 短时繁忙时合并待处理帧，只转换最新帧，避免队列越积越旧。
- 原子化流切换：URL、旋转或镜像改变后，旧连接和旧变换的在途帧会被丢弃，不会在清缓存后回写到新画面。
- 可配置断流策略：保持最后一帧，或在设定超时后恢复真实相机。
- rootless 打包，同时构建 `arm64` 和 `arm64e`。
- 设置修改通过 Darwin 通知实时传递，不需要每次重启 SpringBoard。
- 输入方向统一处理：手机端可设置 0°/90°/180°/270° 旋转与水平镜像，变换一次后供所有相机输出复用。
- 高清源档位：MJPEG 最长边可选 1280、1920、2560 或实验性 3840；iPhone 7 Plus 默认推荐 1920。
- OBS 工作流：Windows 工具默认自动读取当前 OBS Profile 已保存的基础画布、输出分辨率和 FPS，并与实际 DirectShow 发布模式交叉验证；启用 OBS 自带的密码保护 WebSocket 后，还可在不关闭 OBS 的情况下自动启动/刷新 Virtual Camera。
- 一键手机配置：在 `VirtualCamPro-Windows-Control-Center/` 中运行 `install-phone.bat --setup 手机IP`，安装后自动推导电脑到手机所用网卡，写入流 URL 和手机 FPS 上限；设置页可直接检测当前 URL 是否返回真实 JPEG/HLS 数据。
- Windows 可视化控制中心：仓库中的 `VirtualCamPro-Windows-Control-Center/` 是可直接使用的独立工具目录，双击其中的 `VirtualCamPro-Windows控制中心.bat` 即可预检、一键部署、验证安装并启动或诊断 OBS 桥接。
- 独立配套工具：专用目录单独保存 GUI、CLI、运行脚本、正式 Rootless 安装包、部署教程和 SHA-256 清单；`tools/build-windows-standalone.ps1` 可重复生成同样的交付结构。

## 不支持的内容

- 不直接支持 RTSP 或 RTMP URL。可在电脑上转成 HLS 或 MJPEG。
- 不注册新的 `AVCaptureDevice`，也不伪造相机名称、镜头能力、设备型号或 EXIF。
- 不包含越狱隐藏、授权绕过、反调试或反分析功能。
- `BWNodeOutput` 是 iOS 私有实现。项目针对 iOS 15 运行时检测该类和方法；未来系统若改变实现，需要启用兼容模式或适配新注入点。

## 设备要求

- rootless 越狱 iOS 15.x。
- MobileSubstrate、Substitute 或提供兼容接口的注入框架。
- PreferenceLoader。
- 手机和推流电脑网络互通，或自行建立 USB 端口转发。

iPhone 7 Plus（A10）使用 `arm64` slice，项目的默认构建包含该架构。

## 快速使用

1. 下载或进入 [`VirtualCamPro-Windows-Control-Center/`](VirtualCamPro-Windows-Control-Center/)，先运行 `standalone-self-test.bat`，再双击 `VirtualCamPro-Windows控制中心.bat`，点“环境预检”和“一键部署到手机”。完整步骤见[最新部署教程](VirtualCamPro-Windows-Control-Center/DEPLOYMENT.md)。
2. 在 Windows 上安装 FFmpeg 和 OBS Studio。在控制中心点“诊断 OBS 桥接”，或在独立目录运行 `start-obs-vcam.bat --check`；确认通过后点“启动 OBS 桥接”或双击 `start-obs-vcam.bat`。工具会验证 Virtual Camera 确实输出帧，再按 OBS 保存的画布和 FPS（例如 1920×1080@60）建立 MJPEG 服务。

   首次使用先在 OBS 中添加媒体源、设置循环并保存场景。建议在 OBS“工具 → WebSocket 服务器设置”中保留身份验证并启用服务器；以后即使 OBS 已经打开，脚本也能只启动或刷新 Virtual Camera，不会结束 OBS 或丢失未保存场景。未启用时，OBS 关闭状态下的一键启动仍然可用。

   命令行方式仍然保留：

   ```bat
   start-stream.bat obs landscape 1080p 1
   ```

   或循环播放一个视频文件：

   ```bat
   start-stream.bat "D:\Videos\demo.mp4" landscape 1080p 1
   ```

3. 使用 `--setup` 时电脑局域网地址已自动写入；手动安装时再查询，例如 `192.168.1.10`。
4. 手机“设置 → VirtualCamPro”中填写：

   ```text
   http://192.168.1.10:8888/live.mjpg
   ```

5. 保持“应用层兼容模式”关闭，开启“启用画面替换”；可先点“检测当前网络流”验证数据，再重新打开相机应用。

正常情况下只需在 OBS 保存视频设置后双击 `start-obs-vcam.bat`，脚本会自动读取，不需要再执行 `--check FPS`。临时覆盖时仍可运行 `start-obs-vcam.bat 29.97`。手机解码默认使用完整 60 FPS，可在 1–240 间显式设置；实际输出仍由 OBS/DirectShow、网络、手机解码能力和目标相机格式共同决定，工具不会暗中截到 60 FPS。

如果手机预览横竖方向不正确，优先在 VirtualCamPro 中依次尝试“顺时针 90°”或“逆时针 90°”；前置风格需要镜像时再开启“水平镜像输入”。OBS 用户也可以只在 OBS 场景中旋转来源，手机端保持“不旋转”，两端不要重复旋转。

FFmpeg 的简易 MJPEG HTTP 输出一次只服务一个连接。需要多客户端或更稳定的 OBS 工作流时，推荐使用 SRS/MediaMTX 接收 OBS 的 RTMP 并输出 HLS，再填写 `http://电脑IP:端口/live/name.m3u8`。

## 两种注入模式

| 模式 | 网络连接位置 | 覆盖范围 | 使用场景 |
| --- | --- | --- | --- |
| 系统管线（默认） | `mediaserverd` | 系统相机管线，覆盖面更广 | iOS 15 首选 |
| 应用层兼容 | 每个目标应用 | AVFoundation 公开输出/预览/照片接口 | 日志显示系统 Hook 不存在或不生效时 |

网络尚未收到第一帧时保留真实相机输出。收到过网络帧后，默认断流保持最后一帧；若关闭“断流后保持最后一帧”，超过“旧帧超时”后恢复真实相机。两种策略都会在后台持续重连。

系统模式只替换像素缓冲，不改相机设备对象，因此应用和网页仍选择系统已有的“前置/后置相机”，不会出现名为 OBS 的新 iOS 相机。由系统相机保存照片时，元数据来自这台 iPhone 的真实相机管线；应用层兼容模式会从真实捕获中保留 TIFF/EXIF/GPS/Apple 设备信息、修正尺寸，并在接受替换文件前读回核验。若容器无法同时保住替换图和真实设备信息，则保留原相机文件，绝不生成无元数据或伪造设备身份的文件。深度、视差、人物/语义蒙版和 HDR 增益图属于原物理场景；MJPEG 不含重建它们的数据，因此替换照片不会沿用这些不匹配的辅助载荷。

## 项目结构

- `MediaServer.x`：系统相机图低层注入。
- `Tweak.x`：应用层兼容注入。
- `AVAssetStreamAdapter.*`：HLS/MJPEG 接收与重连。
- `VCJPEGParser.h`：可独立测试的增量 JPEG 帧边界解析器。
- `VCFrameConverter.*`：VideoToolbox 像素格式、尺寸和比例转换。
- `VCPreferences.*`：统一偏好读取与校验。
- `VCStreamCoordinator.*`：每进程流生命周期和最新帧管理。
- `prefs/`：PreferenceLoader 设置面板。
- `scripts/validate_project.py`：项目结构与配置一致性检查。
- `VirtualCamPro-Windows-Control-Center/`：可直接下载使用的独立 Windows 控制中心，包含最新版安装包、GUI、CLI、部署教程和完整性验证。
- `VirtualCamPro-Windows-Control-Center/scripts/`：Windows 预检、OBS 控制、FFmpeg 推流、手机安装与验证核心工具。
- `tools/build-windows-standalone.ps1`：从专用目录可重复生成带 SHA-256 清单的发布工具。

首次安装请看[最新部署教程](VirtualCamPro-Windows-Control-Center/DEPLOYMENT.md)。完整推流方案见 [STREAMING.md](STREAMING.md)，Windows 参数与退出码见 [WINDOWS_TOOLS.md](VirtualCamPro-Windows-Control-Center/WINDOWS_TOOLS.md)，构建见 [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md)，设计与研究结果见 [ARCHITECTURE.md](ARCHITECTURE.md)，故障排查见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)，实机验收见 [DEVICE_TEST_PLAN.md](DEVICE_TEST_PLAN.md)，版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 安全边界

仅在你拥有并获准测试的设备和应用中使用。画面替换不等于新硬件相机设备；依赖私有相机管线的行为必须在目标 iOS 小版本和具体应用上实机验证。
