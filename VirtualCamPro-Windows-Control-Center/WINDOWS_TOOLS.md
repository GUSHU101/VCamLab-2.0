# Windows 工具说明

首次部署请先阅读 [DEPLOYMENT.md](DEPLOYMENT.md)。本目录是仓库内唯一的 Windows 独立控制中心，所有命令均从本目录运行。

项目提供统一图形入口 `VirtualCamPro-Windows控制中心.bat`，也保留三个独立入口：`start-obs-vcam.bat`、`start-stream.bat` 和 `install-phone.bat`。批处理只负责兼容参数和双击体验，核心逻辑位于 `scripts/windows-vcam.ps1`、`scripts/install-ios.ps1` 与 `scripts/install-ios-gui.ps1`，要求 Windows PowerShell 5.1 或更高版本。

## 可视化 Windows 控制中心

双击 `VirtualCamPro-Windows控制中心.bat`，即可在一个界面内完成：

- 自动发现 `packages/` 或 `artifacts/` 中最新的 `.deb`，也可手动浏览选择；
- 设置手机 IP、SSH 端口、仅供手机本地文件使用的 1–240 FPS 上限、MJPEG/HLS 传输协议和可选自定义流 URL；
- 点“环境预检”验证 SSH、rootless、`sudo` 和 `dpkg`；
- 点“一键部署到手机”完成上传、包校验、安装、版本验证、临时文件清理和 URL/FPS 配置；
- 点“验证安装”检查 `dpkg` 状态、架构、两个注入 dylib 与配置工具；
- 直接“启动桥接”或打开“桥接诊断”，也可勾选部署成功后自动启动。

界面只保存手机地址、端口、FPS、传输协议、包路径和自动启动桥接选项。自定义流 URL 不持久化，查询参数也不会进入 GUI 日志，避免意外保存访问令牌。SSH 与 `sudo` 密码始终在独立 OpenSSH 终端内交互输入，不被 GUI 接收、记录或写入配置。首次连接的主机指纹确认也在该终端中完成。

正式独立包带有 `standalone-manifest.json`。GUI 启动时会先验证必需文件、PowerShell 语法和不可变交付文件的 SHA-256；`obs-vcam-config.cmd` 是明确允许修改的配置文件，只检查是否存在。

## 手机预检与安装

先确认手机和电脑位于同一网络、手机已经激活 rootless 越狱并安装 OpenSSH，然后运行：

```bat
install-phone.bat --check 192.168.0.103
```

预检会验证 TCP SSH、`/var/jb`、`sudo`、`dpkg` 和实际 `uid=0(root)` 提权。SSH 密码与 `sudo` 密码由 OpenSSH 在当前终端直接读取，工具没有密码参数，也不会记录密码。若 `sudo` 报告“有效用户 ID 不是 0”或 `nosuid`，完整重启后用原越狱工具重新激活同一种 rootless 模式，再重试预检；不要修改已经正确的 setuid 文件权限。

预检通过后安装：

```bat
install-phone.bat 192.168.0.103
```

工具按修改时间选择 `packages/` 或 `artifacts/` 中最新的 `com.murkaska.virtualcampro_*_iphoneos-arm64.deb`，显示本地 SHA-256，通过 SCP 复制到 `/var/mobile`，再在手机端核对上传字节数和完整 SHA-256，并由 `dpkg-deb` 验证包内 ID、版本和架构。只有全部一致才会使用 `mobile + sudo dpkg` 安装；无论验证或安装在哪一步失败，临时上传都会自动清理。也可以显式指定安装包和端口：

```bat
install-phone.bat 192.168.0.103 "D:\Packages\com.murkaska.virtualcampro_2.19.0_iphoneos-arm64.deb" 22
```

希望安装后自动写入手机 URL 和启用替换时使用：

```bat
install-phone.bat --setup 192.168.0.103
```

`--setup` 会根据 `VCAM_TRANSPORT` 自动生成 URL：MJPEG 使用 `http://电脑IP:8888/live.mjpg`，HLS 使用 `http://电脑IP:8888/live.m3u8`。同时保存的 60 FPS 默认值只在以后选择手机本地视频来源时生效；网络流始终采用发送端 FPS、分辨率、质量和方向。可用 `VCAM_PHONE_FPS`、`VCAM_STREAM_URL`、`VCAM_PORT` 和 `VCAM_TRANSPORT` 覆盖。
如果显式填写 `VCAM_STREAM_URL`，工具会检查它与传输协议是否一致：HLS 必须使用 `.m3u8` URL；MJPEG 不能误填 `.m3u8`。协议与地址不匹配时会在写入手机前直接停止并给出错误。

首次连接仍会保留 OpenSSH 的主机密钥确认，不会为了方便而关闭主机身份校验。可用 `VCAM_PHONE_HOST`、`VCAM_PHONE_PORT`、`VCAM_PHONE_USER`、`VCAM_DEB_PATH`、`VCAM_PHONE_FPS`、`VCAM_STREAM_URL` 和 `VCAM_TRANSPORT` 设置默认值。

## 快速检查

```bat
start-obs-vcam.bat --check
```

预检会确认：

- FFmpeg、OBS 与 DirectShow `OBS Virtual Camera` 设备存在；
- 方向、分辨率、帧率、质量、端口、绑定地址和等待时间合法；
- 监听端口没有被其他进程占用，并在冲突时显示进程名和 PID；
- 当前可用的局域网 IPv4 地址及手机应填写的完整 URL。
- OBS Virtual Camera 实际发布的像素格式、分辨率和帧率是否与请求的输出完全一致；
- 当前活动 OBS 场景中可见图片源是否仍使用不会随画布自动填充的自由变换。

`--check` 不启动 OBS，也不修改防火墙。MJPEG 模式需要允许 FFmpeg 入站；HLS 模式由内置 PowerShell HTTP 服务监听，因此需要允许 Windows PowerShell 在专用网络中入站。
请求模式不存在时预检以退出码 `5` 失败，不会只显示警告后返回成功。

## 一键 OBS 工作流

先在 `obs-vcam-config.cmd` 中调整设置，然后双击：

```bat
start-obs-vcam.bat
```

默认 `VCAM_RESOLUTION=auto`、`VCAM_FPS=auto`。启动器从 OBS `user.ini` 定位当前 Profile，再读取 `basic.ini` 中保存的基础画布、缩放输出和 FPS；支持 OBS 的常用、整数及分数三种 FPS 格式。正常保存 OBS 设置后直接双击即可，不要求先运行 `--check`。FFmpeg/OBS 断开重连时还会重新读取 Profile 和活动模式，因此重启 Virtual Camera 后可自动应用新值。

如果 OBS 尚未运行，工具使用官方 `--startvirtualcam` 参数启动它，并实际读取一帧确认虚拟摄像机已经出画面；只检测到进程并不算启动成功。如果 OBS 已经运行，默认通过本机 `127.0.0.1` 上的 OBS WebSocket 5 接口查询并启动/刷新 Virtual Camera，读取 OBS 自己保存的密码完成挑战认证，不显示、记录或复制密码。它只控制 Virtual Camera，不强制结束 OBS。

这项能力需要一次性在 OBS“工具 → WebSocket 服务器设置”中启用服务器；身份验证应保持开启。接口关闭或不可达时脚本安全降级，给出最短的手动操作，OBS 关闭状态下的一键启动不受影响。

用于自动化或从已有终端运行时，可以取消最后的暂停：

```bat
start-obs-vcam.bat --no-pause
```

FPS 可以临时覆盖，不需要修改配置文件：

```bat
start-obs-vcam.bat 29.97
start-obs-vcam.bat --check 29.97
start-obs-vcam.bat --no-pause 30000/1001
```

传输协议也可以临时覆盖，不改配置文件：

```bat
start-obs-vcam.bat --transport mjpeg
start-obs-vcam.bat --transport hls
start-obs-vcam.bat --transport hls --check
```

## 视频文件或手动 OBS 推流

```bat
start-stream.bat obs landscape 1080p 1 30 8888 mjpeg
start-stream.bat obs landscape 1080p 1 30 8888 hls
start-stream.bat "D:\Videos\demo.mp4" portrait 720p 5 30 8888 hls
```

参数依次为：来源、方向、分辨率、MJPEG 质量、帧率、端口、传输协议。HLS 模式会忽略 MJPEG 质量参数；省略的参数从 `obs-vcam-config.cmd` 读取。文件源会先由 `ffprobe` 验证确实包含可读取的视频流，避免启动服务后才发现输入无效。

## 配置项

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| `VCAM_FFMPEG_PATH` | 自动检测 | 可选的 `ffmpeg.exe` 完整路径 |
| `VCAM_OBS_PATH` | 自动检测 | 可选的 `obs64.exe` 完整路径 |
| `VCAM_OBS_SCENE` | 空 | 启动 OBS 时选择的场景 |
| `VCAM_ORIENTATION` | `landscape` | `landscape` 或 `portrait` |
| `VCAM_RESOLUTION` | `auto` | 自动读取 OBS 基础画布；也可指定 `720p`、`1080p`、`1440p` 或 `2160p` |
| `VCAM_FPS` | `auto` | 自动读取 OBS FPS；也接受 1–240 的 `25`、`59.94`、`120`、`240` 或分数 |
| `VCAM_TRANSPORT` | `mjpeg` | `mjpeg` 输出 `/live.mjpg`；`hls` 输出 H.264 `/live.m3u8` |
| `VCAM_QUALITY` | `1` | 1–31，越小越清晰、带宽越高；默认 1 为编码器最高质量 |
| `VCAM_HLS_SEGMENT_SECONDS` | `0.25` | HLS 分片时长，0.2–10 秒；越短通常延迟越低但请求更频繁 |
| `VCAM_HLS_LIST_SIZE` | `6` | HLS 活动播放列表保留的分片数，6–30；Apple 直播兼容要求至少 6 段 |
| `VCAM_HLS_VIDEO_BITRATE_KBPS` | `12000` | H.264 目标视频码率 kbps |
| `VCAM_HLS_MAXRATE_KBPS` | `16000` | H.264 峰值码率上限 kbps |
| `VCAM_HLS_BUFSIZE_KBPS` | `12000` | x264 低延迟 VBV 缓冲 kbps |
| `VCAM_HLS_PRESET` | `ultrafast` | `ultrafast` 到 `medium`；越慢通常压缩效率越高、CPU 越重 |
| `VCAM_SCALE_MODE` | `fill` | `fill` 等比放大后居中裁切、`fit` 等比补边、`stretch` 拉伸 |
| `VCAM_BIND_ADDRESS` | `0.0.0.0` | 监听所有 IPv4 网卡；`127.0.0.1` 仅适合 USB 隧道 |
| `VCAM_PORT` | `8888` | 1024–65535 |
| `VCAM_OBS_WAIT_SECONDS` | `15` | 等待 OBS 实际出帧的最长秒数 |
| `VCAM_RESTART_ON_DISCONNECT` | `true` | MJPEG 断开后重建监听器；HLS 模式用于 FFmpeg 编码器异常退出后的自动重启 |
| `VCAM_RT_BUFFER_MB` | `64` | DirectShow 原始帧短突发缓冲下限；按分辨率/FPS 扩到约 250 ms，最高 256 MiB |
| `VCAM_THREAD_QUEUE_SIZE` | `4` | 独立采集线程队列下限；自动扩到约 250 ms、最多 60 帧 |
| `VCAM_ENCODER_THREADS` | `4` | 软件 MJPEG 并行编码线程；硬件预检通过时可自动改用 Intel Quick Sync |
| `VCAM_OUTPUT_QUEUE_SIZE` | `3` | 已编码网络 FIFO 下限；自动扩到约 150 ms、最多 36 帧，持续拥塞时丢弃旧包 |
| `VCAM_TCP_SEND_BUFFER_MB` | `1` | Windows TCP 发送缓冲，同时启用 TCP_NODELAY 和 keepalive |
| `VCAM_FFMPEG_LOG_LEVEL` | `error` | `error` 保持 GUI 简洁；排障时可设为 `warning` 或 `info` |
| `VCAM_REQUIRE_OBS_MODE_MATCH` | `true` | 要求 OBS 发布模式与输出分辨率/FPS 完全匹配，否则拒绝启动 |
| `VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA` | `true` | OBS 已运行时通过本机认证接口自动启动/刷新 Virtual Camera；不会结束 OBS |
| `VCAM_DEVICE_NAME` | `OBS Virtual Camera` | DirectShow 设备的精确名称 |

MJPEG 模式继续使用 `yuvj420p`、最优 Huffman 表、显式并行线程、已编码 FIFO 和 TCP 低延迟参数，并显式返回标准 `multipart/x-mixed-replace; boundary=ffmpeg` HTTP Content-Type，适合最低延迟局域网预览。HLS 模式使用 `libx264 + yuv420p`，按关键帧边界生成 MPEG-TS 分片和实时 `.m3u8`，由工具自带的 PowerShell HTTP 服务提供文件，不需要额外安装 Nginx、Python 或 Caddy。HLS 显著降低带宽但会增加分片与播放器缓冲延迟。两种模式都保留相同的 OBS 分辨率/FPS/缩放逻辑。默认 `fill` 会等比放大并居中裁切到目标尺寸；这只能处理 OBS 的完整输出画布，不能消除图片源已经在 OBS 场景内形成的空白。图片源需要在 OBS“变换 → 编辑变换”中使用“缩放到外部边界”，并把边界尺寸设成画布尺寸。

OBS“设置 → 视频”的基础画布、输出分辨率和 FPS 必须与脚本一致。修改后要先停止再重新启动 OBS 虚拟摄像机，DirectShow 才会重新发布模式。模式匹配允许最多 0.01 FPS 的驱动报告误差，但会区分 29.97 与 30、59.94 与 60。脚本用英文句点生成 FFmpeg 小数参数，不受 Windows 区域格式影响。

自动读取的是“已保存配置”，DirectShow 检测的是“虚拟摄像机当前活动配置”。如果两者不同，启动器会同时显示，例如 `Saved OBS profile ... 1920x1080@60` 与 `OBS DirectShow modes ... 1020x1344@60`。本机控制接口可用时会自动停止/启动 Virtual Camera 并重新检测；接口关闭时才要求在 OBS 中手动切换一次。任何情况下都不会用旧活动模式静默推流。

手机设置中的 FPS、解码质量、旋转和镜像只用于手机本地文件，不参与网络接收。网络 MJPEG/HLS 的方向、分辨率、帧率和画质全部由本 Windows 工具/OBS 的实际输出决定，音频继续使用手机原生麦克风。

## 恢复与退出码

MJPEG 使用 FFmpeg 的简单 HTTP 监听器，一次只服务一个客户端；手机断开后可在 1 秒后自动重建监听。HLS 使用独立的内置 HTTP 服务，手机断开不会停止编码，播放器会持续轮询 `.m3u8` 与分片。两种模式下，如果 FFmpeg 连续三次在 5 秒内失败，工具都会停止重试，避免错误配置形成无限循环。

按 `Ctrl+C` 时 FFmpeg 可能打印 `Immediate exit requested`。这是手动停止的正常退出，脚本会识别 Windows 的中断退出码并停止恢复循环；如果没有按键却出现该信息，再检查终端是否被关闭或外部程序是否结束了 FFmpeg。

常见退出码：

- `0`：成功；
- `2`：输入文件不存在或没有视频流；
- `3`：FFmpeg、FFprobe 或 OBS 不存在；
- `4`：端口被占用；
- `5`：OBS 虚拟摄像机未注册或没有出帧；
- `64`：配置或参数无效；
- `70`：运行时连续失败或内部自检失败。

开发者可以运行 `start-stream.bat --self-test`，它不需要启动 OBS 或网络监听器；Windows CI 也会执行这一检查。

手机工具的离线参数与命令构造自检为：

```bat
install-phone.bat --self-test
```

独立配套工具可运行聚合自检：

```bat
standalone-self-test.bat
```

2.19.0 的聚合自检依次验证清单/重复路径/不可变文件 SHA-256、全部 PowerShell AST 语法、配置取值边界、OBS WebSocket 认证、手机安装命令、GUI 参数构造与旧配置迁移、WinForms 冒烟启动，并实际启动本机 HLS HTTP 服务验证 GET、HEAD、Range 206 与 OPTIONS/CORS。检测到 FFmpeg 时，还会同时确认 MJPEG 与 `libx264` 编码器，并实际生成临时 H.264 HLS 分片。环境组件缺失属于 `[WARN]`，结构或运行级错误属于 `[FAIL]`。

## 生成独立配套工具

在完整源码目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-windows-standalone.ps1 `
  -PackagePath "D:\Packages\com.murkaska.virtualcampro_2.19.0_iphoneos-arm64.deb" `
  -CreateZip
```

指定 `-PackagePath` 时，输出包含 GUI、三个命令行入口、可编辑配置、全部运行脚本、安装包、中文说明和 `standalone-manifest.json`，不依赖源码目录或 Git。CI 使用 `-AllowMissingPackage` 生成不夹带历史二进制的 Windows 工具 artifact，正式 `.deb` 由同一提交的 `VirtualCamPro-rootless` artifact 单独提供。
