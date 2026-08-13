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

## 系统模式仍显示真实相机

查看日志：

```bash
log stream --style compact --predicate 'eventMessage CONTAINS "VirtualCamPro"'
```

正常应出现：

```text
[VirtualCamPro] mediaserverd BWNodeOutput hook installed
```

若出现 `unavailable on this iOS build`，开启“应用层兼容模式”，完全退出并重新打开目标相机应用。

日志中 `video-type filter enabled` 表示已验证并使用 `BWNodeOutput` 的视频媒体类型过滤。`Skipping non-color or unsupported ...` 只记录一次，表示某个深度/视差或未知像素输出被安全透传；若普通前后摄像头始终不替换，记录该数值以便在实机确认后扩充支持列表。

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

- 视频横着显示：在手机“输入画面旋转”中尝试顺时针 90°或逆时针 90°。
- OBS 已经旋转来源时，手机必须保持“不旋转”；两端同时旋转会再次变错。
- 自拍风格左右相反时开启“水平镜像输入”，不要用旋转代替镜像。
- 全屏裁切过多时关闭“填满画面”；出现黑边但需要满屏时重新开启，并在 OBS 中把主体放在安全区域。
- 修改方向后旧帧会立即清除；下一网络帧到达前短暂显示真实相机属于安全回退。
- 只有视频源全屏、图片源不全屏：这是 OBS 场景源变换，不是手机裁切。运行 `start-obs-vcam.bat --check` 查看被点名的图片源；在 OBS“变换 → 编辑变换”中选择“缩放到外部边界”，边界尺寸设为画布尺寸。

## OBS 缓冲过满或 FFmpeg 报 Immediate exit requested

`real-time buffer ... too full` 是 FFmpeg DirectShow 采集线程来不及取走原始帧的错误，不是单纯的日志噪声。常见原因是单线程 JPEG 编码、60 FPS MJPEG 带宽过高，或手机/TCP 读取变慢后把网络背压传回采集端。先运行：

```bat
start-obs-vcam.bat --check
```

修复后的桥接保持原始 FPS 和质量，使用 4 个 MJPEG 编码线程，以 256 MiB 为下限并按分辨率/FPS 扩到约半秒的 DirectShow 缓冲、至少半秒输入队列、至少一秒已编码 FIFO 和 4 MiB TCP 发送缓冲。短时编码或 Wi-Fi 波动由各层缓冲吸收，HTTP 写入不会再直接堵塞 OBS 采集；只有持续超过物理网络吞吐时才会淘汰已经失去实时价值的输出包。

新版默认自动读取当前 OBS Profile 的已保存分辨率和采集 FPS，正常启动不需要手动执行 `--check`。OBS 发布的 29.97 与 30、59.94 与 60 是不同采集模式；保存值与 DirectShow 活动值不同时，启用 OBS“工具 → WebSocket 服务器设置 → 启用 WebSocket 服务器”后，脚本会使用本机挑战认证自动刷新 Virtual Camera。服务器关闭时才需手动停止/启动一次。

`VCAM_FFMPEG_LOG_LEVEL=warning` 或 `info` 可用于观察 FIFO 丢包和时间戳，排查结束后恢复 `error`。不要首先增大 `VCAM_RT_BUFFER_MB`；它无法解决持续背压。

手动按 `Ctrl+C` 时出现 `Immediate exit requested` 是 FFmpeg 正常响应中断，不是编码故障；脚本会直接停止，不再误判为断流并重新启动。

## 画面卡顿、清晰度低或延迟高

- 默认保持 OBS 的原始 FPS 并使用 MJPEG 最高质量 1；有界 FIFO 只在网络真正拥塞时丢弃无法及时发送的输出帧，不主动降帧率或降低画质。
- 清晰度不足时先确认 OBS 输出为 1920×1080，手机“MJPEG 解码上限”为 1920，并避免把竖屏窄画面缩进横屏画布后再放大。
- 2560/3840 档位会显著增加 MJPEG 带宽和 BGRA 内存；启用前应先确认手机内存压力日志、5 GHz/有线链路吞吐和编码余量，程序不会暗中降低已选择的档位。
- HLS：减小服务端 segment/window，但普通 HLS 通常仍比 MJPEG 延迟高。
- 1080p60 是完整支持路径。持续卡顿时先使用 5 GHz Wi-Fi/USB 转发、关闭占用手机 GPU/内存的后台任务、确认 Windows 编码速度大于实时速度，并检查 FIFO/TCP 吞吐；工具不会通过暗中限制 FPS 或降低 JPEG 质量来掩盖瓶颈。
- 2.8.0 起手机端会在 Wi-Fi 突发或 GPU 短时繁忙时合并中间帧、优先显示最新帧；日志中的 `Coalesced ... intermediate network frames` 表示低延迟保护生效，不是配置被降帧。若持续频繁出现，应先扩容网络和释放解码/GPU 负载。
- 系统模式只有一个解码连接；应用兼容模式开启多个相机应用会产生多条连接。
- 出现 `Released conversion caches after warning/critical memory pressure` 是正常自保护；严重压力下可能短暂透传一帧真实相机，新网络帧到达后会自动恢复。

## 预览画面与录像、照片或应用实际输入不一致

新版在应用层兼容模式中优先把“已经按相机输出模板转换完成的同一像素缓冲”送到预览层，并使用完整画面显示，避免预览对原始网络帧再做一次不同的裁切。照片的 `previewPixelBuffer`、主 `pixelBuffer`、CGImage 和最终文件也锁定同一个网络源帧，不会在各接口调用间取到不同时间的画面。

最终照片会读回核对替换尺寸和真实 TIFF/EXIF/GPS/Apple 信息。原相机的深度、视差、人物/语义蒙版、HDR 增益图及辅助图描述的是另一场景，不能与 MJPEG 网络画面可信配对，因此不会复制到替换照片；这避免了照片内部主图与场景数据互相矛盾。

Windows 端仍应确保 OBS 画布就是希望发送的最终构图；`VCAM_SCALE_MODE=fill` 会在 Windows 输出阶段裁切，手机的“填满画面”则决定同一网络帧如何适配相机模板。方向和镜像只在 OBS 或手机其中一端设置一次。更新 iOS 源码后必须重新构建并安装 `.deb`，旧 2.8.0 二进制不会自动包含这项一致性修复。

## 应用或浏览器没有出现“OBS 相机”

这是设计边界，不是设备注册失败。插件替换现有 iPhone 相机管线中的颜色帧，不注册新的 `AVCaptureDevice`，因此应用和网页仍只会列出系统已有的前置/后置相机。先保持“应用层兼容模式”关闭，选择任意真实相机并观察其画面是否被替换。

Safari/网页还必须在正常的系统相机授权和安全上下文中调用 `getUserMedia`。如果系统模式在某个 WebKit 页面没有替换，再开启“应用层兼容模式”，彻底关闭 Safari/目标浏览器后重开；2.5.0 已增加 WebKit 内容进程注入。兼容模式的每个目标进程会建立自己的网络连接，而简单 MJPEG 监听器一次只服务一个连接，所以不要同时打开多个相机标签页。应用使用自研/非 AVFoundation 管线时仍需单独适配，不能通过伪造设备名称稳定解决。

## 相机应用崩溃

先关闭插件；若无法进入设置，按 [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) 的“紧急禁用”重命名两个 dylib。然后收集：

```bash
ls -lt /var/mobile/Library/Logs/CrashReporter/ | head
log show --last 5m --style compact --predicate 'process == "mediaserverd" OR eventMessage CONTAINS "VirtualCamPro"'
```

系统模式崩溃而兼容模式正常时，说明当前 iOS 构建的私有相机图行为与 iOS 15 预期不同；保留兼容模式并附带崩溃日志进行适配。

## 断流后出现静止画面

默认行为是保留最后一帧，同时按 1、2、4、8、16、30 秒的退避间隔重连。接收器还会检测“15 秒内没有首帧”或“连续 8 秒没有新帧”的半断开连接并主动重建。

如果希望断流后恢复真实相机，关闭“断流后保持最后一帧”，并设置“旧帧超时”。关闭“启用画面替换”会立即恢复真实相机。
