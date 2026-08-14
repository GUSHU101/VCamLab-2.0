# VirtualCamPro Windows 控制中心 2.18.0 部署教程

本目录是可直接使用的 Windows 独立控制中心，包含图形控制中心、OBS/FFmpeg 桥接工具、命令行工具和完整性清单。为避免混用历史二进制，源码仓库不附带 `.deb`；请从同一提交的 GitHub Actions `VirtualCamPro-rootless` artifact 下载正式 Rootless 安装包并放入本目录的 `packages/`。普通用户不需要复制仓库根目录中的 iOS 源码。

## 1. 使用条件

- Windows 10/11，Windows PowerShell 5.1 或更高版本。
- OBS Studio，且 OBS 虚拟摄像机能够正常启动。
- FFmpeg/FFprobe 已加入 `PATH`，或在 `obs-vcam-config.cmd` 中填写完整路径。
- iOS 15 Rootless 越狱设备，已安装 PreferenceLoader、OpenSSH、`sudo` 和 `dpkg`。
- 手机和电脑位于可互访的同一局域网；默认需要放行 TCP 8888。

仅在你拥有并获准测试的设备和应用中使用。工具不会收集或保存 SSH、sudo、OBS WebSocket 密码。

## 2. 先验证下载完整性

解压后不要只复制单个脚本。保留整个目录结构，然后双击：

```bat
standalone-self-test.bat
```

2.18.0 的 `standalone-self-test.bat` 不再只做文件哈希检查：它还会实际启动 GUI 冒烟测试、核心脚本 SelfTest、本机 HLS HTTP 服务，并验证 GET / HEAD / HTTP Range 206 / OPTIONS+CORS；如果检测到 FFmpeg，还会同时检查 MJPEG 与 libx264 编码器，并实际生成一小段 H.264 HLS 测试流。看到最终 `[OK]` 后再继续。如果完整性或运行级检查失败，优先处理第一条 `[FAIL]`；除 `obs-vcam-config.cmd` 外，不要单独修改交付文件。

## 3. 准备 OBS 输出

1. 在 OBS“设置 → 视频”中设置最终画布、输出分辨率和 FPS，例如 `1920×1080 @ 60 FPS`。
2. 添加媒体源、图片或采集源，完成缩放、裁切和旋转后保存场景。
3. 图片需要无变形铺满时，在“变换 → 编辑变换”中使用“缩放到外部边界”，边界尺寸设为 OBS 画布尺寸。
4. 建议在“工具 → WebSocket 服务器设置”中启用带身份验证的服务器。控制中心可以在不关闭 OBS 的情况下启动或刷新 Virtual Camera。

默认 `obs-vcam-config.cmd` 使用 `VCAM_TRANSPORT=mjpeg` 和 MJPEG 最高质量 `VCAM_QUALITY=1`，并自动读取 OBS 保存的分辨率和 FPS。需要 HLS 时可选择“HLS / H.264”；低延迟默认使用 0.25 秒分片、6 段播放列表、`libx264 ultrafast`，并写入独立分片和节目时间戳。工具不会暗中修改用户指定的 OBS FPS/分辨率。

## 4. 检查手机环境

先确认手机 IP，例如 `192.168.1.103`。双击 `VirtualCamPro-Windows控制中心.bat`，填写手机地址后点击“环境预检”。也可以使用命令行：

```bat
install-phone.bat --check 192.168.1.103
```

预检必须确认 `/var/jb`、`sudo`、`dpkg` 和 `uid=0(root)` 全部可用。默认 SSH 用户是 `mobile`；密码只在系统 OpenSSH 终端中交互输入。

如果 `sudo` 返回非 root、`nosuid` 或越狱未激活，不要反复改权限或强制安装。完整重启设备，用原越狱工具重新激活同一种 Rootless 环境后再次预检。

## 5. 一键安装和配置

图形界面推荐流程：

1. 从同一提交的 GitHub Actions `VirtualCamPro-rootless` artifact 取得 `.deb`，放入本目录 `packages/`；工具会自动识别，也可在界面中手动选择。
2. “手机本地视频最高 FPS”默认 `60`，它不限制网络流；网络参数跟随 OBS/Windows 发送端。
3. 点击“一键部署到手机”。
4. 工具会核对本地 SHA-256、上传字节数、手机端包 ID/版本/架构和安装后的精确版本，然后删除手机中的临时上传文件。
5. 部署完成后点击“验证安装”。

命令行等价操作：

```bat
install-phone.bat --setup 192.168.1.103
```

`--setup` 会自动推导电脑到手机所用的局域网 IPv4，并按照传输协议写入：

```text
MJPEG: http://电脑局域网IP:8888/live.mjpg
HLS:   http://电脑局域网IP:8888/live.m3u8
```

如果手工填写流地址，控制中心会检查协议与 URL 是否一致，避免选中 HLS 却把 `live.mjpg` 写入手机，或选中 MJPEG 却误填 `.m3u8`。

只安装、不改变手机现有流设置时运行：

```bat
install-phone.bat 192.168.1.103
```

## 6. 启动高质量 OBS 桥接

在控制中心先选择 **MJPEG** 或 **HLS / H.264**，再点击“诊断 OBS 桥接”。诊断必须看到 OBS Virtual Camera 已注册、活动模式与保存的画布/FPS 一致，并能实际读取视频帧。随后点击“启动 OBS 桥接”。也可以双击：

```bat
start-obs-vcam.bat
```

保持桥接窗口打开。默认 MJPEG 服务地址为 `http://电脑局域网IP:8888/live.mjpg`。HLS 模式使用 `http://电脑局域网IP:8888/live.m3u8`。命令行可直接运行 `start-obs-vcam.bat --transport hls` 或 `start-obs-vcam.bat --transport mjpeg`。

MJPEG 模式使用多线程 JPEG、约 100–150 ms 的短输入缓冲、3–12 帧编码 FIFO 和 TCP_NODELAY。持续拥塞时优先丢弃旧包而不是积累秒级延迟。HLS 模式使用 H.264/x264、250 ms 关键帧对齐分片和内置 HTTP 文件服务；它仍比 MJPEG 延迟高，实时使用优先选择 MJPEG。

## 7. 手机端启用与验收

1. 打开“设置 → VirtualCamPro”。
2. 确认“启用画面替换”开启，“应用层兼容模式”默认关闭。
3. 确认流 URL 正确，点击“检测当前网络流”。2.18.0 iOS 包同时包含 MJPEG 接收器、VideoToolbox/ImageIO 自动解码路径和基于 AVPlayer 的 HLS `.m3u8` 接收路径。
4. 彻底退出并重新打开相机或目标应用。
5. 验证预览、录像、照片和目标应用输入来自同一 OBS 构图。
6. 验证横竖屏、前后摄、Live Photo、连拍及常用第三方相机客户端。

系统模式不会注册名为 OBS 的新 iOS 摄像头；目标应用仍选择真实前置或后置相机，但其颜色帧会被替换。兼容模式照片会尽可能保留并读回核验这台 iPhone 真实捕获产生的 TIFF/EXIF/GPS/Apple 设备信息；如果无法同时保证替换像素与真实元数据，插件会保留原始相机文件，不伪造设备身份。

## 8. 更新、回退与卸载

更新时必须替换整个 `VirtualCamPro-Windows-Control-Center/` 目录，再运行 `standalone-self-test.bat`，不要把新旧脚本混用。重新执行“一键部署”即可覆盖安装同一包 ID 的新版本。

完全卸载：

```bash
ssh mobile@PHONE_IP
sudo dpkg -r com.murkaska.virtualcampro
```

紧急情况下先在“设置 → VirtualCamPro”关闭替换。无法进入设置时，按仓库根目录 [BUILD_INSTRUCTIONS.md](../BUILD_INSTRUCTIONS.md) 中的紧急禁用步骤操作。

## 9. 常用诊断

控制中心内可直接点击 **“深度自检”**；命令行等价方式：

```bat
standalone-self-test.bat
```

深度自检将配置损坏、旧版 `deploy-gui.json` 异常字段、WinForms 初始化、MJPEG/HLS 编码器能力和 HLS HTTP Range/CORS 都纳入检查。缺少 OBS/OpenSSH 等当前环境组件会显示 `[WARN]`；脚本/GUI/HLS 运行级错误显示 `[FAIL]` 并返回非零退出码。

```bat
start-obs-vcam.bat --check
install-phone.bat --verify 192.168.1.103
standalone-self-test.bat
```

- `exit 4`：服务端口被占用。
- `exit 5`：OBS Virtual Camera 未注册、模式不匹配或没有真实输出帧。
- `real-time buffer ... too full`：先确认正在使用本目录最新版工具，再检查诊断输出、OBS 活动模式、编码速度和网络吞吐；不要先降低质量或 FPS。
- 预览与最终输入不同：OBS 画布必须就是最终构图，方向和镜像只在 OBS 或手机其中一端设置一次。

完整参数见 [WINDOWS_TOOLS.md](WINDOWS_TOOLS.md)，更多排障见仓库根目录的 [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)。
