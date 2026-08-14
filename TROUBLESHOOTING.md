# 故障排查

本文中的 Windows 命令均在 `VirtualCamPro-Windows-Control-Center/` 独立工具目录中执行。

## SSH 可登录但 sudo 报 effective UID 或 nosuid

先确认问题发生在提权而不是密码或安装包：

```bash
ls -l /var/jb/usr/bin/sudo
sudo -v
```

即使权限显示为 `-rwsr-xr-x root wheel`，`sudo -v` 仍可能因为越狱未完整激活、启用了隐藏越狱，或 `/private/preboot` 的 setuid 语义没有恢复而失败。此时 `command -v sudo` 只能证明文件存在，不能证明提权可用。

不要反复尝试 `sudo`、不要手动 `chmod`、不要使用 `dpkg --force-*`。完整重启手机，关闭“Hide Jailbreak/隐藏越狱”，再用原工具重新激活同一种 rootless 越狱。Windows 可用下面的检查确认恢复：

```bat
install-phone.bat --check PHONE_IP
```

只有检查显示 `uid=0(root)` 后才继续安装。`dpkg -s` 显示 `deinstall ok config-files` 仅表示旧包已经删除但保留配置，不代表插件仍已安装。

## 设置中没有 VirtualCamPro

检查：

```bash
dpkg -l | grep -i virtualcam
ls -la /var/jb/Library/PreferenceBundles/VirtualCamPro.bundle
ls -la /var/jb/Library/PreferenceLoader/Preferences/VirtualCamPro.plist
```

确认 PreferenceLoader 已安装，然后重启“设置”应用或执行一次 userspace reboot。

## 完全不能替换，而且系统日志为空

先确认安装版本为 2.23.0 或更高。该版本不再依赖 unified log 才能判断注入链路：先打开目标相机应用 10 秒，再切回“设置 → VirtualCamPro → 复制运行诊断信息”。重点查看：

- `springBoardRuntime`：无存活信号表示生产者插件未注入；旧的“正在稳定产帧”会被忽略，不再当作当前有效状态。
- `mediaServerRuntime`：无存活信号表示 `VCMediaServer.dylib` 没有进入 mediaserverd，优先检查安装路径、filter plist 和注入框架。
- `mediaServerVideoStage`：可直接区分找不到 `BWNodeOutput`、签名不兼容、Hook 已安装、共享来源不可见、格式不支持、转换失败和替换成功。
- `applicationVideoStage`：记录相机应用是否真正进入 AVFoundation Hook、delegate 是否接管、预览是否显示替换帧以及照片替换结果；切回设置后仍保留最后阶段和发生时间。

若 `mediaServerRuntime` 存活且阶段停在“Hook 已安装”，但打开相机后始终没有“共享来源不可见/转换失败/替换成功”，说明该相机模式没有经过当前识别的 `BWNodeOutput emitSampleBuffer:` 入口；2.23.0 会持续低频重扫，但仍需把完整诊断发回用于扩展真机入口。若应用阶段显示“预览已显示替换帧”而实际界面没有变化，则问题位于目标应用的图层合成顺序，而不是解码或共享帧。

## 点击 VirtualCamPro 后设置闪退

先确认安装的是 2.22.0 或更高版本。该版本不再在页面加载阶段安装自定义 table header，也不为设置面板单独链接 QuartzCore；动态状态只在导航转场结束后使用 iOS 15 兼容的一参数 selector 刷新。可选刷新异常会自动停表，原生开关和来源配置仍应可用。

如果 2.22.0 仍闪退，先从 `/var/mobile/Library/Logs/CrashReporter/` 导出最新的 `Preferences-*.ips` 或 `Preferences-*.crash`，不要只提供“闪退”截图：

```bash
ls -lt /var/mobile/Library/Logs/CrashReporter/Preferences* | head
```

同时执行 `dpkg -s com.murkaska.virtualcampro`，确认版本和架构。崩溃日志中的 `Exception Type`、`Termination Reason` 和崩溃线程回溯可以区分 PreferenceLoader 类加载、缺失动态符号、Objective-C selector 与其他第三方设置插件冲突；没有这些证据不能把所有闪退归因于相机媒体管线。

## 选择本地视频时提示导入失败

先确认安装的是 2.22.0 或更高版本。旧版在文件复制后立即同步读取 AVAsset 轨道，照片、iCloud、刚完成编辑/旋转的视频，以及提供器返回的无后缀临时文件，都可能被误报为“不包含可识别的视频或音频轨道”。2.22.0 会先按内容类型修复文件后缀，再让导入和实际播放共用可取消、30 秒总预算的异步轨道加载器；瞬时空轨道或解析失败会用全新的 `AVURLAsset` 重试一次，PHPicker 同时要求兼容表示和真实视频轨道。

- “读取媒体轨道超时”：视频可能仍在 iCloud，先在照片中完整播放或下载后重试。
- “AVFoundation 无法读取”：保留的错误详情表示容器损坏、受保护或编码不受当前 iOS 支持。
- “确认不包含视频或音频轨道”：文件容器确实没有可播放轨道；优先转换为 MP4/MOV（H.264/HEVC）或 M4A/MP3。

旋转按钮只在导入成功后作用于解码帧，不参与导入判定。因此此提示不是 90°/180°/270° 变换本身产生的。

如果导入成功但开始播放时仍失败，请保留日志中的 `Local media error`。`Timed out while loading local video geometry` 表示轨道存在但方向/尺寸元数据没有在 30 秒内就绪；先在“照片”中完整下载原片，或转为普通 H.264/AAC MP4 后重试。切换来源会取消旧加载，因此不需要重启 SpringBoard 清理卡住的读取。

## 统一系统管线仍显示真实相机

查看日志：

```bash
log stream --style compact --predicate 'eventMessage CONTAINS "VirtualCamPro"'
```

正常应出现：

```text
[VirtualCamPro] mediaserverd BWNodeOutput hooks installed (... classes, video typed, audio typed)
```

若出现 `unavailable on this iOS build`，标准 AVFoundation 数据输出会在当前样本没有系统替换证据时立即执行应用层回退，无需等待全局心跳或切换设置。完全退出并重开目标应用；`AVCaptureMovieFileOutput` 等无法完整回退的路径需要针对该 iOS 小版本适配系统 Hook。

日志中 `video typed, audio typed` 表示已验证并使用 `BWNodeOutput` 的媒体类型过滤。`Preserving non-color ...` 只记录一次，表示某个深度/视差或未知像素输出被安全透传；若普通前后摄像头始终不替换，记录该数值以便在实机确认后扩充支持列表。

## 没有网络画面

1. 手机“设置 → VirtualCamPro”先点“检测当前网络流”；它会检查 HTTP 状态、内容类型及真实 JPEG/HLS 标记。Windows 的 `start-obs-vcam.bat --check` 可进一步只读诊断端口、DirectShow 设备和局域网 URL；正常启动时还应看到 `OBS Virtual Camera is producing frames`。
2. 手机 Safari 打开 HLS URL，或用 SSH 测试：

   ```bash
   curl -v --max-time 5 http://电脑IP:8888/live.mjpg
   ```

3. URL 必须是 HTTP/HTTPS。`.m3u8` 才按 HLS 处理，其余 URL 按 MJPEG 处理。
4. URL 中不要填写 `localhost`；`VCAM_BIND_ADDRESS=127.0.0.1` 也只适合已经配置 USB 隧道的场景。
5. 允许 FFmpeg/SRS/MediaMTX 通过 Windows 防火墙。
6. 手机和电脑在同一局域网，且路由器没有启用客户端隔离。

Windows 工具的 `exit 4` 表示端口被占用，`exit 5` 表示 OBS 虚拟摄像机未注册或没有实际输出帧。具体进程、参数和恢复策略见 [WINDOWS_TOOLS.md](VirtualCamPro-Windows-Control-Center/WINDOWS_TOOLS.md)。

如果控制中心提示“独立工具完整性检查失败”，先运行 `standalone-self-test.bat` 查看具体文件。除 `obs-vcam-config.cmd` 外，不要单独覆盖或编辑交付脚本；安装包变化后应重新运行独立工具构建器生成清单。

## 方向、镜像或裁切不正确

- 网络流：只在 OBS 场景或 Windows 发送画布中旋转、镜像和裁切。手机会忽略本地视频方向设置，保证网络像素不被二次处理。
- 手机本地文件：使用“本地视频旋转”“水平镜像本地视频”和“本地视频填满画面”；修改后 reader 会安全重启并清除旧方向帧。
- 屏幕镜像：跟随设备显示方向，不使用本地文件设置。
- 只有视频源全屏、图片源不全屏：这是 OBS 场景源变换，不是手机裁切。运行 `start-obs-vcam.bat --check` 查看被点名的图片源；在 OBS“变换 → 编辑变换”中选择“缩放到外部边界”，边界尺寸设为画布尺寸。

## OBS 缓冲过满或 FFmpeg 报 Immediate exit requested

`real-time buffer ... too full` 是 FFmpeg DirectShow 采集线程来不及取走原始帧的错误，不是单纯的日志噪声。常见原因是单线程 JPEG 编码、60 FPS MJPEG 带宽过高，或手机/TCP 读取变慢后把网络背压传回采集端。先运行：

```bat
start-obs-vcam.bat --check
```

低延迟桥接保持原始 FPS 和质量。启动时会在当前分辨率/FPS/质量下实测软件 MJPEG，并在 Intel Quick Sync 真正可创建且达到实时余量时自动使用 `mjpeg_qsv`；仅在编码器列表中出现但驱动不可用时不会误选。DirectShow 原始缓冲和采集队列覆盖约 250 ms 瞬时突发，已编码 FIFO 覆盖约 150 ms，并继续在持续拥塞时淘汰旧包，避免积累秒级延迟。

新版默认自动读取当前 OBS Profile 的已保存分辨率和采集 FPS，正常启动不需要手动执行 `--check`。OBS 发布的 29.97 与 30、59.94 与 60 是不同采集模式；保存值与 DirectShow 活动值不同时，启用 OBS“工具 → WebSocket 服务器设置 → 启用 WebSocket 服务器”后，脚本会使用本机挑战认证自动刷新 Virtual Camera。服务器关闭时才需手动停止/启动一次。

`VCAM_FFMPEG_LOG_LEVEL=warning` 或 `info` 可用于观察 FIFO 丢包和时间戳，排查结束后恢复 `error`。不要首先增大 `VCAM_RT_BUFFER_MB`；它无法解决持续背压。

手动按 `Ctrl+C` 时出现 `Immediate exit requested` 是 FFmpeg 正常响应中断，不是编码故障；脚本会直接停止，不再误判为断流并重新启动。

## 画面卡顿、清晰度低或延迟高

- 默认保持 OBS 的原始 FPS 并使用 MJPEG 最高质量 1；有界 FIFO 只在网络真正拥塞时丢弃无法及时发送的输出帧，不主动降帧率或降低画质。
- 网络清晰度不足时检查 OBS/FFmpeg 实际输出分辨率和 `VCAM_QUALITY`；手机不会再对 MJPEG 设置解码上限或二次降质。
- 2560/3840 档位会显著增加 MJPEG 带宽和 BGRA 内存；启用前应先确认手机内存压力日志、5 GHz/有线链路吞吐和编码余量，程序不会暗中降低已选择的档位。
- HLS：减小服务端 segment/window，但普通 HLS 通常仍比 MJPEG 延迟高。
- 1080p60 是完整支持路径。持续卡顿时先使用 5 GHz Wi-Fi/USB 转发、关闭占用手机 GPU/内存的后台任务、确认 Windows 编码速度大于实时速度，并检查 FIFO/TCP 吞吐；工具不会通过暗中限制 FPS 或降低 JPEG 质量来掩盖瓶颈。
- 手机端会在 Wi-Fi 突发或 GPU 短时繁忙时覆盖尚未解码/处理的旧帧、优先显示最新帧；这属于有界低延迟保护，不是手机端主动降低发送帧率。若画面仍持续跳帧，应先扩容网络、确认 Windows 编码速度大于实时速度并释放手机解码/GPU 负载。
- 无论打开多少相机应用，都只有 SpringBoard 的一个解码连接；应用自动回退只映射共享 IOSurface，不重新拉流。
- 出现 `Released conversion caches after warning/critical memory pressure` 是正常自保护；严重压力下可能短暂透传一帧真实相机，新网络帧到达后会自动恢复。

## 预览画面与录像、照片或应用实际输入不一致

系统主路径在 `mediaserverd` 内统一替换样本，预览、录像和处理回调自然得到同一内容。当前样本没有系统替换证据时，应用自动回退优先把“已经按相机输出模板转换完成的同一像素缓冲”送到预览层；另一个 Session 的全局心跳不会影响这次判断。照片的 `previewPixelBuffer`、主 `pixelBuffer`、CGImage 和最终文件也锁定同一个共享源帧。

最终照片会读回核对替换尺寸和真实 TIFF/EXIF/GPS/Apple 信息。原相机的深度、视差、人物/语义蒙版、HDR 增益图及辅助图描述的是另一场景，不能与替换画面可信配对，因此不会复制到替换照片。

Windows 端应确保 OBS 画布就是希望发送的最终网络构图；`VCAM_SCALE_MODE=fill` 在 Windows 输出阶段裁切。手机“本地视频填满画面”和方向设置不会影响网络流。更新 iOS 源码后必须通过 GitHub Actions/macOS 重新构建并安装同提交的 `.deb`，不要混用历史二进制。

## 应用或浏览器没有出现“OBS 相机”

这是设计边界，不是设备注册失败。插件替换现有 iPhone 相机管线中的真实媒体样本，不注册新的 `AVCaptureDevice`，因此应用和网页仍只会列出系统已有的前置/后置相机。选择任意真实相机并观察其内容是否被系统媒体图替换。

Safari/网页仍必须在正常的系统相机授权和安全上下文中调用 `getUserMedia`。WebKit 当前样本没有系统替换证据时会自动使用 AVFoundation 回退；设置页心跳只用于显示 mediaserverd 最近是否工作。彻底关闭 Safari/目标浏览器后重开即可。所有进程都消费同一 IOSurface，不会建立第二条 MJPEG 连接。应用使用自研/非 AVFoundation 管线时仍需单独适配，不能通过伪造设备名称稳定解决。

## 相机应用崩溃

先关闭插件；若无法进入设置，按 [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) 的“紧急禁用”重命名两个 dylib。然后收集：

```bash
ls -lt /var/mobile/Library/Logs/CrashReporter/ | head
log show --last 5m --style compact --predicate 'process == "mediaserverd" OR eventMessage CONTAINS "VirtualCamPro"'
```

如果 `mediaserverd` 进入崩溃循环，说明当前 iOS 构建的私有相机图行为与已验证的 iOS 15 版本不同。先禁用插件恢复相机，再附带崩溃日志适配；不要通过扩大 Hook 范围掩盖签名或格式不匹配。

## 断流后出现静止画面

默认行为是保留最后一帧，同时按 1、2、4、8、16、30 秒的退避间隔重连。接收器还会检测“15 秒内没有首帧”或“连续 8 秒没有新帧”的半断开连接并主动重建。

如果希望断流后恢复真实相机，关闭“断流后保持最后一帧”，并设置“旧帧超时”。关闭“启用画面替换”会立即恢复真实相机。

## 本地文件结束后画面静止或麦克风恢复

关闭“循环播放本地媒体”后，自然播放到结尾会在控制面板显示“本地媒体播放完成”。共享音频会立即失效，因此带音轨视频或纯音频文件不会在结尾后继续占用虚拟麦克风；下一次系统麦克风回调会恢复原生输入。

画面行为由“断流后保持最后一帧”决定：开启时保留文件最后一帧，关闭时按“旧帧超时”恢复真实相机。切换来源、点“重载当前来源”或停用插件不会显示为自然播放完成。
