# 构建和安装

## 推荐：GitHub Actions

Windows 无法直接使用 Xcode 的新 arm64e ABI 链接器，因此完整的 `arm64 + arm64e` rootless 构建应在 macOS 或本仓库的 GitHub Actions 上完成。

1. 推送到 `main` 或创建面向 `main` 的 Pull Request；也可在 Actions 手动运行 `Build rootless package`。
2. Actions 会安装固定提交的 Theos/iOS SDK，编译 `arm64 + arm64e`，再核对包 ID、版本、架构、rootless 文件布局、Mach-O、plist、维护脚本权限和 SHA-256。
3. 构建成功后下载 `VirtualCamPro-rootless` artifact。
4. 解压后得到 `.deb`、`SHA256SUMS` 和记录源码/Theos/SDK 提交的 `build-metadata.txt`。

`Source validation` 会同时运行带 ASan/UBSan 的 C 协议测试、Shell 配置自检、PowerShell 5.1/WinForms/FFmpeg 深度自检，并重建不捆绑旧 iOS 二进制的 Windows 独立工具。所有第三方 Actions 都固定到完整提交 SHA，工作流只授予 `contents: read`。

## macOS 本地构建

要求：Xcode、Theos、`ldid`、`xz`，以及 Theos 可识别的 iOS SDK。

```bash
export THEOS="$HOME/theos"
make clean
python3 scripts/validate_project.py
make package FINALPACKAGE=1
bash scripts/verify_deb.sh packages/com.murkaska.virtualcampro_2.11.0_iphoneos-arm64.deb
```

仅为 iPhone 7 Plus/A10 构建时，可临时减少到 arm64：

```bash
make clean
make package FINALPACKAGE=1 ARCHS=arm64
```

发布包建议保留默认双架构。

## 生成 Windows 独立配套工具

仓库在 `VirtualCamPro-Windows-Control-Center/` 保存控制中心和旧版正式 `.deb`。统一系统管线属于当前源码改动，必须先由 GitHub Actions/macOS 重新构建，再从新包生成交付目录：

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-windows-standalone.ps1 `
  -PackagePath "D:\Packages\com.murkaska.virtualcampro_2.11.0_iphoneos-arm64.deb" `
  -CreateZip
```

生成目录不包含 iOS 源码或 Git 历史，只包含运行控制中心所需的 GUI、CLI 入口、脚本、文档、安装包和完整性清单。交付前应在生成目录运行 `standalone-self-test.bat`。

普通部署不需要重新构建。请进入 `VirtualCamPro-Windows-Control-Center/` 并按照 [DEPLOYMENT.md](VirtualCamPro-Windows-Control-Center/DEPLOYMENT.md) 操作。

## 安装到 rootless 设备

以下命令均在 `VirtualCamPro-Windows-Control-Center/` 内执行。Windows 推荐先检查手机的 SSH、rootless bootstrap、`sudo` 和 `dpkg`；预检不会复制或安装文件：

不想使用命令行时，可直接双击 `VirtualCamPro-Windows控制中心.bat`，在图形界面中点“环境预检”和“一键部署到手机”。界面还集成了 OBS 桥接启动和诊断。

```bat
install-phone.bat --check PHONE_IP
```

检查通过后，一键选择 `packages/` 或 `artifacts/` 中最新的 `.deb`，显示 SHA-256，复制并安装：

```bat
install-phone.bat PHONE_IP
```

推荐首次安装直接完成流地址配置：

```bat
install-phone.bat --setup PHONE_IP
```

`--setup` 会推导电脑访问该手机时使用的局域网 IPv4，写入 `http://电脑IP:8888/live.mjpg` 并启用替换。`VCAM_PHONE_FPS` 保存的是手机本地文件的最高 FPS（默认 60），不会限制网络流；网络分辨率、FPS、质量和方向由发送端决定。只安装而不改变已有手机设置时使用普通安装命令。

也可以把 `.deb` 完整路径作为第二个参数、SSH 端口作为第三个参数：

```bat
install-phone.bat PHONE_IP "D:\Downloads\com.murkaska.virtualcampro_2.11.0_iphoneos-arm64.deb" 22
```

工具固定使用 Windows OpenSSH 的交互式密码提示，不接收或保存密码。复制后还会核对上传字节数，并用手机端 `dpkg-deb` 验证包内 ID、版本和架构；安装后要求已安装版本精确一致，随后删除 `/var/mobile` 中的临时上传。默认用户是 `mobile`；可通过 `VCAM_PHONE_USER`、`VCAM_PHONE_PORT`、`VCAM_PHONE_HOST` 和 `VCAM_DEB_PATH` 环境变量覆盖。

手动安装时，以 `mobile` 用户把包复制到手机：

```bash
scp packages/com.murkaska.virtualcampro_*.deb mobile@PHONE_IP:/var/mobile/
```

登录手机，先确认 `sudo` 真正能够提权，再安装：

```bash
ssh mobile@PHONE_IP
sudo -v
sudo dpkg -i /var/mobile/com.murkaska.virtualcampro_*.deb
dpkg -s com.murkaska.virtualcampro | grep -E '^(Status|Version|Architecture):'
```

`command -v sudo` 或文件存在并不等于提权可用，安装前必须以 `sudo -v` 的退出结果为准。若出现“有效用户 ID 不是 0”或 `nosuid`，不要反复输入密码、修改 setuid 位或强制安装；完整重启后用原工具重新激活同一种 rootless 越狱，再重新执行 `--check`。

包内 `postinst` 会在安装成功后自动重启 SpringBoard、`mediaserverd`、相机和设置进程。若包管理器报告已安装但旧进程仍在，可手动执行：

```bash
sudo killall mediaserverd
sudo killall Camera 2>/dev/null || true
sudo killall Preferences 2>/dev/null || true
sudo killall SpringBoard
```

也可以在 Sileo、Zebra 或 Filza 中打开 `.deb` 安装。rootless 文件应出现在：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.dylib
/var/jb/Library/PreferenceBundles/VirtualCamPro.bundle
```

## 卸载或紧急禁用

优先在设置中关闭“启用画面替换”。若设置界面不可用，可通过 SSH 禁用两个注入文件：

```bash
sudo mv /var/jb/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.dylib /var/jb/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.dylib.disabled
sudo mv /var/jb/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.dylib /var/jb/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.dylib.disabled
sudo killall mediaserverd
sudo killall SpringBoard
```

恢复时改回原文件名。完全卸载：

```bash
sudo dpkg -r com.murkaska.virtualcampro
```

卸载脚本会在文件移除后重启相机相关进程，使已经加载到内存的 dylib 立即退出。

## 安装前检查

- 确认设备存在 `/var/jb`。
- 确认 `sudo -v` 成功且 `sudo id` 返回 `uid=0(root)`。
- 确认 PreferenceLoader 已安装。
- 确认推流 URL 能在手机 Safari 或 `curl` 中访问。
- 防火墙放行 TCP 8888（MJPEG）或 HLS 服务端口。
- 默认验收使用 OBS 保存的 1920×1080@60 与 MJPEG 最高质量 `-q:v 1`，确认日志没有 DirectShow 溢出且手机没有持续内存压力。2560/3840 或 120/240 FPS 必须同步验证编码余量、网络吞吐与手机内存；工具不会暗中降低 FPS、分辨率或质量。
