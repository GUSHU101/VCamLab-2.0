# 推流方案

Windows 命令均在仓库的 `VirtualCamPro-Windows-Control-Center/` 独立工具目录中执行。

## 方案一：OBS Virtual Camera → MJPEG

适合单台手机快速测试，延迟通常低于普通 HLS。

1. 安装 OBS Studio 和 FFmpeg，并确认 `ffmpeg -version` 可运行。
2. 在 OBS 中添加“媒体源”，开启循环，完成裁切/旋转，然后保存场景。
3. `obs-vcam-config.cmd` 默认自动读取当前 OBS Profile 保存的基础画布和 FPS，MJPEG 使用最高质量 1、缩放模式为等比填充；如果希望脚本启动时自动切到指定场景，把 `VCAM_OBS_SCENE` 设置成 OBS 中完全一致的场景名称。
4. 直接双击 `start-obs-vcam.bat`。工具会自动读取已保存的 OBS 分辨率/FPS、检测端口和 DirectShow 活动模式，并用当前画布、帧率和质量做一次短编码余量测试。Intel Quick Sync MJPEG 只有在运行时会话和基准都通过时才会自动启用；否则继续使用软件编码。OBS 未运行时使用官方 `--startvirtualcam` 参数启动并实际读取一帧后才建立 MJPEG 服务。`--check` 只是可选的只读诊断。窗口必须保持打开，按 `Ctrl+C` 可停止服务。

   建议一次性在 OBS“工具 → WebSocket 服务器设置”中启用带身份验证的服务器。OBS 已运行时脚本即可自动启动或仅刷新 Virtual Camera，不会结束 OBS，也不会丢失场景；服务器关闭时才提示点击一次按钮。

   原命令行方式仍可使用：

   ```bat
   start-stream.bat obs landscape 1080p 1
   ```

5. 可运行 `install-phone.bat --setup PHONE_IP` 自动写入 `http://电脑局域网IP:8888/live.mjpg`；也可手动填写。手机设置中的“检测当前网络流”会验证真实 JPEG/HLS 数据。

正常双击 `start-obs-vcam.bat` 时已经自动执行配置读取和活动模式检查；`--check` 只是可选的只读诊断。已保存配置若与活动模式不同，控制接口可用时会自动刷新 Virtual Camera。`start-stream.bat` 的参数依次为“来源、画布方向、清晰度、MJPEG 质量、帧率、端口”。完整配置见 [WINDOWS_TOOLS.md](VirtualCamPro-Windows-Control-Center/WINDOWS_TOOLS.md)。

帧率接受 1–240 的整数、小数和分数。例如 `start-obs-vcam.bat 29.97`、`120` 或 `240`。OBS 必须真实发布相同 DirectShow 模式；29.97 与 30、59.94 与 60 会被视为不同帧率。

OBS“设置 → 视频”中把基础画布和输出分辨率设为目标档位（默认 1920×1080、60 FPS）。添加“媒体源”并开启循环，在来源变换中完成裁切、适配以及 90° 旋转，然后启动 OBS 虚拟摄像机。播放过程中使用媒体源工具栏或“设置 → 热键”配置播放/暂停、重新开始和显示/隐藏；暂停媒体源时 OBS 仍连续输出静止帧，手机连接不会中断。

图片源不会因为修改画布而自动重新排版。希望不变形地铺满画布时，在“变换 → 编辑变换”中把边界类型设为“缩放到外部边界”、边界尺寸设为 `1920×1080`；允许拉伸时可使用“拉伸到屏幕”。脚本的 `fill` 只能裁切整个 OBS 输出，无法识别并放大画布内部某一张图片。

网络方向必须在 OBS/Windows 发送端配置。手机对网络帧不做旋转、镜像、FPS 限制或质量缩放，只用独立的最新帧解码槽淘汰网络突发中的过期帧。手机的方向、镜像、FPS 和解码质量设置仅用于“手机本地视频”来源。

FFmpeg 的 `-listen 1` 输出一次只接受一个客户端。默认启用恢复循环，手机断开后会在 1 秒内重新监听；连续三次快速失败时停止，避免无限错误重试。

## 方案二：OBS → SRS → HLS

适合长期运行、多客户端和自动重连。可使用 [LiuSky/iOS-vcam](https://github.com/LiuSky/iOS-vcam) 中的 Windows SRS 启动器，也可以自行安装[官方 SRS](https://github.com/ossrs/srs)。

1. 把 `streaming/srs-vcam.conf` 放到 SRS 根目录。
2. 启动：

   ```text
   objs\srs.exe -c streaming\srs-vcam.conf
   ```

3. OBS“设置 → 直播”：

   ```text
   服务：自定义
   服务器：rtmp://127.0.0.1:1935/live
   推流码：vcam
   ```

4. OBS 输出建议：H.264、目标分辨率与源 FPS、无 B 帧或低延迟 preset；仓库 Windows 工具使用 0.25 秒关键帧/分片和 6 段活动窗口，并写入独立分片与节目时间戳。手机不设置 HLS 解码 FPS，实际帧率完全取决于发送流和设备硬件。
5. 手机设置 URL：

   ```text
   http://电脑局域网IP:8080/live/vcam.m3u8
   ```

按 [SRS HLS 文档](https://github.com/ossrs/srs/wiki/v2_EN_DeliveryHLS)，HLS 分片的实际长度不会小于编码 GOP，因此 OBS 的关键帧间隔必须与 `hls_fragment` 配合。配置使用 1 秒分片、4 秒窗口；网络不稳定时可把它们调整为 2 秒和 8 秒。

## 方案三：视频文件 → MJPEG

```bat
start-stream.bat "D:\Videos\demo.mp4" landscape 1080p 1 30 8888
```

工具先用 `ffprobe` 验证文件包含视频流，再按明确选择的分辨率和 FPS 循环输出 MJPEG。第二个参数控制方向，第三个参数选择分辨率，第四至第六个参数分别设置 FFmpeg 质量、帧率和端口。例如最高质量 60 FPS 文件测试使用 `landscape 1080p 1 60 8888`。

`2160p` 只用于实验：网络 MJPEG 会按发送端完整 4K 像素解码，不受手机“本地视频解码质量”影响；A10 上 4K MJPEG 30 FPS 仍可能高温或出现解码压力。长期运行优先使用 1080p MJPEG，或接受更高延迟使用硬件解码 HLS。

## 网络检查

Windows 查询 IPv4：

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' }
```

放行端口：MJPEG 为 TCP 8888；SRS 为 TCP 1935（OBS 推入）和 TCP 8080（手机下载 HLS）。不要把 `127.0.0.1` 或 `localhost` 填进手机，除非已经配置 USB 隧道。
