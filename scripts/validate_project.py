#!/usr/bin/env python3
"""Fast repository consistency checks that do not require an iOS SDK."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROL_CENTER = "VirtualCamPro-Windows-Control-Center"
ERRORS: list[str] = []


def fail(message: str) -> None:
    ERRORS.append(message)


def read_text(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing file: {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def control_center_path(relative: str) -> str:
    return f"{CONTROL_CENTER}/{relative}"


def read_plist(relative: str):
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing plist: {relative}")
        return None
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception as exc:  # pragma: no cover - error path only
        fail(f"invalid plist {relative}: {exc}")
        return None


def validate_plists() -> None:
    for path in sorted(ROOT.rglob("*.plist")):
        try:
            with path.open("rb") as handle:
                plistlib.load(handle)
        except Exception as exc:
            fail(f"invalid plist {path.relative_to(ROOT)}: {exc}")


def validate_makefile() -> None:
    makefile = read_text("Makefile")
    required_fragments = (
        "THEOS_PACKAGE_SCHEME = rootless",
        "TARGET = iphone:clang:16.5:15.0",
        "ARCHS ?= arm64 arm64e",
        "TWEAK_NAME = AVFCameraSupport VCMediaServer",
        "MediaServer.x",
        "VCFrameConverter.m",
        "VCStreamCoordinator.m",
        "VideoToolbox",
        'chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postrm"',
    )
    for fragment in required_fragments:
        if fragment not in makefile:
            fail(f"Makefile missing: {fragment}")

    for match in re.finditer(r"^[A-Za-z0-9_]+_FILES\s*=\s*(.+)$", makefile, re.MULTILINE):
        for source in match.group(1).split():
            if not (ROOT / source).is_file():
                fail(f"Makefile references missing source: {source}")


def validate_preferences() -> None:
    constants = read_text("VCPreferences.m")
    root_plist = read_plist("prefs/Resources/Root.plist") or {}
    items = root_plist.get("items", [])
    keyed_items = {item.get("key"): item for item in items if item.get("key")}
    expected_keys = {
        "enabled",
        "compatibilityMode",
        "streamURL",
        "preferredFPS",
        "sourceRotation",
        "mirrorSource",
        "maximumPixelDimension",
        "jpegQuality",
        "aspectFill",
        "holdLastFrame",
        "staleFrameTimeout",
    }
    missing = expected_keys - keyed_items.keys()
    if missing:
        fail(f"settings UI missing keys: {', '.join(sorted(missing))}")

    notification = "com.murkaska.virtualcampro/preferences.changed"
    for key in expected_keys:
        item = keyed_items.get(key, {})
        if item.get("defaults") != "com.murkaska.virtualcampro":
            fail(f"wrong preference domain for {key}")
        if item.get("PostNotification") != notification:
            fail(f"missing preference notification for {key}")
        if f'@"{key}"' not in constants:
            fail(f"VCPreferences.m missing constant value for {key}")

    if keyed_items.get("enabled", {}).get("default") is not False:
        fail("enabled must default to false")
    if keyed_items.get("compatibilityMode", {}).get("default") is not False:
        fail("system mediaserverd mode must be the default")
    if keyed_items.get("holdLastFrame", {}).get("default") is not True:
        fail("holdLastFrame must default to true")
    if keyed_items.get("sourceRotation", {}).get("default") != 0:
        fail("sourceRotation must default to zero")
    if keyed_items.get("mirrorSource", {}).get("default") is not False:
        fail("mirrorSource must default to false")
    if keyed_items.get("preferredFPS", {}).get("default") != 60:
        fail("preferredFPS must default to the full supported 60 FPS")
    if keyed_items.get("jpegQuality", {}).get("default") != 1.0:
        fail("replacement photo JPEG quality must default to the maximum value")
    maximum_dimension_item = keyed_items.get("maximumPixelDimension", {})
    if maximum_dimension_item.get("default") != 1920 or maximum_dimension_item.get("validValues") != [1280, 1920, 2560, 3840]:
        fail("maximumPixelDimension must expose the validated 1280-3840 presets")
    stale_item = keyed_items.get("staleFrameTimeout", {})
    if (stale_item.get("default"), stale_item.get("min"), stale_item.get("max")) != (8.0, 2.0, 30.0):
        fail("staleFrameTimeout must default to 8 seconds with a 2-30 second range")

    example = read_plist("example-config.plist") or {}
    for key in expected_keys:
        if key not in example:
            fail(f"example-config.plist missing key: {key}")
    setup_script = read_text("setup-config.sh")
    for key in expected_keys:
        if f"<key>{key}</key>" not in setup_script:
            fail(f"setup-config.sh missing key: {key}")
    for fragment in ('PREFERRED_FPS="${2:-60}"', 'validate_preferred_fps()',
                     '"$vc_fps" -lt 1', '"$vc_fps" -gt 240'):
        if fragment not in setup_script:
            fail(f"setup-config.sh missing FPS validation: {fragment}")


def validate_filters() -> None:
    app_filter = read_plist("AVFCameraSupport.plist") or {}
    app_classes = set(app_filter.get("Filter", {}).get("Classes", []))
    expected_classes = {
        "AVCaptureVideoDataOutput",
        "AVCaptureVideoPreviewLayer",
        "AVCapturePhoto",
    }
    if app_classes != expected_classes:
        fail("AVFCameraSupport class filter is inconsistent")
    app_bundles = set(app_filter.get("Filter", {}).get("Bundles", []))
    if app_bundles != {
        "com.apple.UIKit",
        "com.apple.UIKitCore",
        "com.apple.WebKit.WebContent",
    }:
        fail("AVFCameraSupport application/WebKit bundle filter is inconsistent")

    media_filter = read_plist("VCMediaServer.plist") or {}
    executables = media_filter.get("Filter", {}).get("Executables", [])
    if executables != ["mediaserverd"]:
        fail("VCMediaServer must inject only into mediaserverd")


def validate_package() -> None:
    control = read_text("control")
    fields = {}
    for line in control.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    expected = {
        "Package": "com.murkaska.virtualcampro",
        "Version": "2.8.0",
        "Architecture": "iphoneos-arm64",
    }
    for key, value in expected.items():
        if fields.get(key) != value:
            fail(f"control {key} must be {value}")
    prefs_info = read_plist("prefs/Info.plist") or {}
    if prefs_info.get("CFBundleShortVersionString") != fields.get("Version"):
        fail("preference bundle short version must match control Version")
    if prefs_info.get("CFBundleVersion") != fields.get("Version"):
        fail("preference bundle build version must match control Version")
    if "firmware (>= 15.0)" not in fields.get("Depends", ""):
        fail("control must require iOS 15 or newer")
    if "firmware (<< 16.0)" not in fields.get("Depends", ""):
        fail("control must reject unvalidated iOS 16 or newer")


def validate_sources() -> None:
    attributes = read_text(".gitattributes")
    if "layout/DEBIAN/* text eol=lf" not in attributes:
        fail("maintainer scripts must keep LF line endings")
    for fragment in ("*.txt text eol=lf", "*.json text eol=lf", "*.deb binary"):
        if fragment not in attributes:
            fail(f"standalone delivery attributes missing: {fragment}")
    gitignore = read_text(".gitignore")
    if "/artifacts/" not in gitignore.splitlines():
        fail("downloaded GitHub artifacts must remain ignored")

    all_text = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for pattern in ("*.m", "*.h", "*.x", "*.xm")
        for path in ROOT.glob(pattern)
    )
    banned_patterns = {
        "jailbreak path hiding": r"/Applications/Cydia\.app|P_TRACED|LOCAL-BYPASS",
        "direct RTSP claim/implementation": r"rtsp://",
        "device identity spoofing": r"%hook\s+AVCaptureDevice\b",
    }
    for label, pattern in banned_patterns.items():
        if re.search(pattern, all_text):
            fail(f"unexpected {label} code remains")

    required_symbols = (
        "BWNodeOutput",
        "VTPixelTransferSessionTransferImage",
        "VCCopyReplacementSampleBuffer",
        "CMSampleBufferGetSampleAttachmentsArray",
        "AVPlayerItemVideoOutput",
        "com.murkaska.virtualcampro.hls-frames",
        "QOS_CLASS_USER_INTERACTIVE",
        "VCVideoDataOutputProxy",
        "VCResetFrameConverterCache",
        "VCFlushFrameConverterCaches",
        "VCIsSupportedReplacementPixelFormat",
        "CMVideoFormatDescriptionMatchesImageBuffer",
        "CVPixelBufferPoolCreatePixelBufferWithAuxAttributes",
        "VTPixelTransferSessionInvalidate",
        "DISPATCH_SOURCE_TYPE_MEMORYPRESSURE",
        "mediaTypeIsVideo",
        "VCMethodReturnsBoolean",
        "os_unfair_lock",
        "startHealthMonitor",
        "CGImageSourceCreateThumbnailAtIndex",
        "VCMethodAcceptsSampleBuffer",
        "VCPhotoDataByReplacingPrimaryImage",
        "VCPhotoDataPreservesAuthenticMetadata",
        "VCCopyPixelBufferApplyingOrientation",
        "VCCopyDisplayPixelBuffer",
        "imageByApplyingCGOrientation",
        "maximumPixelDimension",
        "_preferencesRefreshGeneration",
        "_streamGeneration",
        "_transformGeneration",
        "VCMaximumJPEGFrameBytes",
        "VCMaximumMJPEGBufferBytes",
        "VCMJPEGBufferCompactionThresholdBytes",
        "_mjpegBufferOffset",
        "compactMJPEGReceiveBufferLockedIfNeeded",
        "_mjpegReceiveLock",
        "VCMaximumOutstandingMJPEGBuffers = 6",
        "VCJPEGParserConsume",
        "VCMaximumOutstandingBuffersPerFormat",
        "VCPhotoFileDataAssociationKey",
        "VCPhotoSourceSnapshotAssociationKey",
        "VCPhotoSourceSnapshot",
        "VCPhotoHasCompatibilityReplacement",
        "VCPhotoUsesReplacement",
        "VCSystemPipelineIsReceivingReplacement",
        "isSystemPipelineReplacementConfigured",
        "VCStreamStatusHoldingLastFrame",
        "semanticSegmentationMatteForType",
        "portraitEffectsMatte",
        "depthData",
        "publishCompatibilityOutputPixelBuffer",
        "copyLatestCompatibilityOutputPixelBufferWithActivePath",
        "kCGImageDestinationLossyCompressionQuality",
        "metadata-preserving JPEG fallback",
        "preserving the authentic original camera file",
        "frame-processing",
        "enqueueLatestPixelBuffer",
        "processPendingPixelBuffers",
        "Coalesced %lu intermediate network frames",
        "latestJPEGData",
        "VCStreamStatusNotificationName",
        "notify_set_state",
    )
    for symbol in required_symbols:
        if symbol not in all_text:
            fail(f"missing implementation symbol: {symbol}")

    converter = read_text("VCFrameConverter.m")
    for obsolete_cache in ("VCConvertedFrameCache", "VCPixelBufferPools"):
        if obsolete_cache in converter:
            fail(f"converter still uses per-frame Foundation cache: {obsolete_cache}")
    if "VCMaximumCachedFormats = 12" not in converter:
        fail("converter cache must remain explicitly bounded")
    if "VCMaximumOutstandingBuffersPerFormat = 6" not in converter:
        fail("converter in-flight buffer allowance must remain explicitly bounded")
    if "VCBoundedPixelBufferAllocationAttributes" not in converter:
        fail("orientation and output pixel-buffer allocations must share a hard threshold")
    if "CFEqual(entry->templateDescription, templateDescription)" not in converter:
        fail("converter must reuse semantically equivalent format descriptions")
    coordinator = read_text("VCStreamCoordinator.m")
    if "@synchronized (self)" in coordinator:
        fail("coordinator hot path must not regress to an Objective-C monitor")
    adapter = read_text("AVAssetStreamAdapter.m")
    if "VCMaximumPreferredFPS = 240" not in adapter or \
            "MIN(VCMaximumPreferredFPS, preferredFPS)" not in adapter:
        fail("stream adapter must preserve the documented 1-240 FPS range")
    if "self.hlsFrameQueue" not in adapter or "dispatch_get_main_queue());\n    dispatch_source_set_timer(self.frameTimer" in adapter:
        fail("HLS frame polling must remain isolated from application main-thread stalls")
    if "_preferredFPS = 60" not in adapter or "_configuredFPS = 60" not in coordinator:
        fail("phone decode and preview must default to the full 60 FPS path")
    if "24 * 1024 * 1024" not in adapter or "32 * 1024 * 1024" not in adapter:
        fail("MJPEG parser safety limits are missing")
    if "parsedImageLength > VCMaximumJPEGFrameBytes" not in adapter:
        fail("completed MJPEG frames must enforce the single-frame safety limit")
    if "latestJPEGData = [imageData subdataWithRange" not in adapter:
        fail("MJPEG burst handling must retain the newest complete frame")
    if "NSMakeRange(0, imageLength)" in adapter:
        fail("MJPEG hot path must not shift the receive buffer after every frame")
    if adapter.count("session != self.session || dataTask != self.task") < 2:
        fail("MJPEG callbacks must revalidate their session while holding the receive-state lock")
    if "_pendingPixelBuffer" not in coordinator or "_frameProcessingScheduled" not in coordinator:
        fail("coordinator must coalesce pending frames on its processing queue")
    if coordinator.count("publishStreamStatus:VCStreamStatusConnecting") < 4:
        fail("system photo status must be invalidated whenever the latest replacement frame is cleared")
    tweak = read_text("Tweak.x")
    if "overlay.contentsGravity = outputPathActive" not in tweak:
        fail("compatibility preview must render the actual converted output without a second crop")
    if "@synchronized (photo)" not in tweak or "snapshot.pixelBuffer" not in tweak:
        fail("photo preview and final image must share one atomic source-frame snapshot")
    for fragment in (
        "VCPhotoReplacementModeAssociationKey",
        "VCReplacementModeForPhoto",
        "VCPhotoReplacementModeCompatibility",
        "VCPhotoReplacementModeSystem",
    ):
        if fragment not in tweak:
            fail(f"photo replacement decision is not frozen per capture: {fragment}")
    if "@synchronized (self)" not in tweak or "&VCPhotoFileDataAssociationKey,\n                                     resultData" not in tweak:
        fail("photo file representation must be generated once and cached atomically")
    if "if (!VCPhotoUsesReplacement(self)) return %orig;" not in tweak:
        fail("inactive or fail-open photos must bypass file rewriting completely")
    if "UIImageJPEGRepresentation" in tweak:
        fail("photo replacement must not fall back to a metadata-free UIKit JPEG")
    if "CGImageDestinationAddAuxiliaryDataInfo" in tweak:
        fail("photo replacement must not attach scene data from the original physical capture")
    for scene_data_method in (
        "- (AVDepthData *)depthData",
        "- (AVPortraitEffectsMatte *)portraitEffectsMatte",
        "- (AVSemanticSegmentationMatte *)semanticSegmentationMatteForType:",
    ):
        if scene_data_method not in tweak:
            fail(f"replacement photo must suppress mismatched scene data: {scene_data_method}")
    if "isEqualToDictionary:sourceMakerApple" not in tweak:
        fail("photo replacement must read back and exactly verify authentic Apple maker metadata")
    if "sourceImageCount == 0" not in tweak or "sourceType,\n        1," not in tweak:
        fail("photo replacement must not leak secondary images from the original physical scene")
    parser_test = read_text("tests/test_jpeg_parser.c")
    for scenario in (
        "testIncrementalBaselineAndEmbeddedThumbnail",
        "testProgressiveScans",
        "testDefineNumberOfLinesInsideScan",
        "testInvalidStructure",
        "testConcatenatedFramesReturnOneFrameAtATime",
        "testMarkerSplitAcrossCallbacks",
        "testInvalidSegmentLengthAndMissingSOI",
    ):
        if scenario not in parser_test:
            fail(f"JPEG parser test missing scenario: {scenario}")
    preference_controller = read_text("prefs/VCPRootListController.m")
    if 'import "../VCJPEGParser.h"' not in preference_controller:
        fail("preference stream test must share the production JPEG parser")
    if "VCJPEGParserConsume(jpegBytes" not in preference_controller:
        fail("preference stream test must structurally validate a complete JPEG")
    if "subdataWithRange" in preference_controller:
        fail("preference stream test must not copy every incoming network chunk")

    obsolete = (
        "AntiDetection.x",
        "RuntimeProtection.x",
        "VirtualCamPro.plist",
        "VirtualCamPro-Windows控制中心.bat",
        "start-obs-vcam.bat",
        "start-stream.bat",
        "install-phone.bat",
        "standalone-self-test.bat",
        "obs-vcam-config.cmd",
        "WINDOWS_TOOLS.md",
        "scripts/windows-vcam.ps1",
        "scripts/obs-websocket.ps1",
        "scripts/install-ios.ps1",
        "scripts/install-ios-gui.ps1",
        "scripts/verify-standalone.ps1",
    )
    for relative in obsolete:
        if (ROOT / relative).exists():
            fail(f"obsolete file still present: {relative}")

    srs_config = read_text("streaming/srs-vcam.conf")
    for fragment in ("hls_fragment        1", "hls_window          4", "hls_wait_keyframe   on"):
        if fragment not in srs_config:
            fail(f"SRS configuration missing: {fragment}")

    windows_stream = read_text(control_center_path("start-stream.bat"))
    for fragment in ("windows-vcam.ps1", "-Mode Stream", "--check", "--self-test"):
        if fragment not in windows_stream:
            fail(f"Windows streaming script missing: {fragment}")

    obs_launcher = read_text(control_center_path("start-obs-vcam.bat"))
    for fragment in (
        "obs-vcam-config.cmd",
        "windows-vcam.ps1",
        "-Mode Obs",
        "--check",
        "--gui",
        "--no-pause",
        "VCAM_QUALITY=1",
        "VCAM_ENCODER_THREADS=4",
        "VCAM_OUTPUT_QUEUE_SIZE=64",
        "VCAM_TCP_SEND_BUFFER_MB=4",
    ):
        if fragment not in obs_launcher:
            fail(f"OBS launcher missing: {fragment}")

    obs_config = read_text(control_center_path("obs-vcam-config.cmd"))
    for fragment in (
        "VCAM_FFMPEG_PATH",
        "VCAM_OBS_PATH",
        "VCAM_OBS_SCENE",
        "VCAM_ORIENTATION=landscape",
        "VCAM_RESOLUTION=auto",
        "VCAM_FPS=auto",
        "VCAM_QUALITY=1",
        "VCAM_SCALE_MODE=fill",
        "VCAM_PORT=8888",
        "VCAM_RT_BUFFER_MB=256",
        "VCAM_THREAD_QUEUE_SIZE=32",
        "VCAM_ENCODER_THREADS=4",
        "VCAM_OUTPUT_QUEUE_SIZE=64",
        "VCAM_TCP_SEND_BUFFER_MB=4",
        "VCAM_FFMPEG_LOG_LEVEL=error",
        "VCAM_REQUIRE_OBS_MODE_MATCH=true",
        "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA=true",
        "VCAM_RESTART_ON_DISCONNECT=true",
    ):
        if fragment not in obs_config:
            fail(f"OBS launcher configuration missing: {fragment}")

    phone_installer = read_text(control_center_path("install-phone.bat"))
    for fragment in ("install-ios.ps1", "--check", "--setup", "--verify", "--self-test", "VCAM_PHONE_HOST"):
        if fragment not in phone_installer:
            fail(f"Windows phone installer missing: {fragment}")

    phone_tool = read_text(control_center_path("scripts/install-ios.ps1"))
    for fragment in (
        "Test-PhoneHostValue",
        "Test-PhonePackageName",
        "Test-PhoneTcpPort",
        "New-PhoneCheckCommand",
        "New-PhoneInstallCommand",
        "New-PhoneSetupCommand",
        "New-PhoneVerifyCommand",
        "Resolve-PhoneLocalIPv4",
        "Invoke-PhoneNativeCommand",
        "Invoke-PhoneSSH",
        "Invoke-PhoneSCP",
        "dpkg-deb",
        "unexpected package architecture",
        '"$sudo_path" -v',
        "Get-FileHash -Algorithm SHA256",
        "uploaded package size mismatch",
        "uploaded package SHA-256 mismatch",
        "trap cleanup_upload EXIT HUP INT TERM",
        "ServerAliveInterval=15",
        "installed version",
        'rm -f "$remote_package"',
        "Invoke-PhoneSelfTest",
        "LogPath",
        '$parsed -gt 240',
    ):
        if fragment not in phone_tool:
            fail(f"PowerShell phone installer missing: {fragment}")

    phone_gui_launcher = read_text(control_center_path("VirtualCamPro-Windows控制中心.bat"))
    for fragment in ("install-ios-gui.ps1", "--self-test", "--smoke-test"):
        if fragment not in phone_gui_launcher:
            fail(f"Windows control-center launcher missing: {fragment}")
    for fragment in ("goto gui_self_test", "goto gui_smoke_test"):
        if fragment not in phone_gui_launcher:
            fail(f"Windows control-center launcher must preserve test exit status: {fragment}")
    phone_gui = read_text(control_center_path("scripts/install-ios-gui.ps1"))
    phone_gui_bytes = (ROOT / control_center_path("scripts/install-ios-gui.ps1")).read_bytes()
    if not phone_gui_bytes.startswith(b"\xef\xbb\xbf"):
        fail("Windows control center must keep a UTF-8 BOM for Chinese PowerShell 5.1 UI text")
    for fragment in (
        "System.Windows.Forms",
        "Get-GuiLatestPackage",
        "New-GuiInstallerCommand",
        "Start-GuiPhoneOperation",
        "Start-GuiBridge",
        "Start-GuiBridgeCheck",
        "start-obs-vcam.bat",
        '"{0}" --gui',
        'Mode "Verify"',
        "startBridgeAfterDeploy",
        "Invoke-GuiSelfTest",
        "Test-GuiStandaloneIntegrity",
        "verify-standalone.ps1",
        "SmokeTest",
    ):
        if fragment not in phone_gui:
            fail(f"Windows control center missing: {fragment}")
    for forbidden in ("SSHPassword", "SudoPassword", "PasswordChar"):
        if forbidden in phone_gui:
            fail(f"Windows control center must not collect passwords: {forbidden}")
    if "streamURL = $script:StreamBox.Text.Trim()" in phone_gui:
        fail("Windows control center must not persist potentially tokenized stream URLs")
    for fragment in (
        "[string]::IsNullOrWhiteSpace($path) -or",
        "[string]::IsNullOrWhiteSpace($packagePath) -or",
    ):
        if fragment not in phone_gui:
            fail(f"Windows control center must safely reject an empty package path: {fragment}")

    for relative in (
        control_center_path("standalone-self-test.bat"),
        control_center_path("standalone-manifest.json"),
        control_center_path("使用说明.txt"),
        control_center_path("DEPLOYMENT.md"),
        control_center_path("packages/com.murkaska.virtualcampro_2.8.0_iphoneos-arm64.deb"),
        control_center_path("scripts/verify-standalone.ps1"),
        "tools/build-windows-standalone.ps1",
    ):
        if not (ROOT / relative).is_file():
            fail(f"standalone companion-tool source missing: {relative}")
    bundled_packages = sorted((ROOT / CONTROL_CENTER / "packages").glob("*.deb"))
    if len(bundled_packages) != 1:
        fail("Windows control center must contain exactly one current Rootless package")
    standalone_builder = read_text("tools/build-windows-standalone.ps1")
    standalone_verifier = read_text(control_center_path("scripts/verify-standalone.ps1"))
    for fragment in (
        "standalone-manifest.json",
        "Get-FileHash",
        "verify-standalone.ps1",
        "start-stream.bat",
        "install-phone.bat",
    ):
        if fragment not in standalone_builder:
            fail(f"standalone builder missing: {fragment}")
    for fragment in (
        "standalone-manifest.json",
        "SHA-256 mismatch",
        "ParseFile",
        "allowedConfigNames",
        "Unsafe command metacharacter",
        "Unmanifested file found",
        "ReparsePoint",
    ):
        if fragment not in standalone_verifier:
            fail(f"standalone verifier missing: {fragment}")
    if "packageIncluded" not in standalone_builder:
        fail("standalone manifest must declare whether it contains an iOS package")
    for launcher in (
        control_center_path("start-obs-vcam.bat"),
        control_center_path("start-stream.bat"),
    ):
        launcher_text = read_text(launcher)
        verify_at = launcher_text.find("verify-standalone.ps1")
        config_at = launcher_text.find("call \"%~dp0obs-vcam-config.cmd\"")
        if verify_at < 0 or config_at < 0 or verify_at > config_at:
            fail(f"{launcher} must verify the mutable config before executing it")

    windows_tool = read_text(control_center_path("scripts/windows-vcam.ps1"))
    for fragment in (
        "ConvertTo-VcamFrameRate",
        "Format-VcamFrameRate",
        "Test-VcamFrameRateMatch",
        "ConvertFrom-VcamIniText",
        "Get-VcamObsSavedVideoSettings",
        "Video.FPSType",
        "30000/1001",
        "Get-VcamPortOwner",
        "Test-VcamObsDeviceRegistered",
        "Test-VcamObsFrame",
        "Start-VcamObs",
        "Test-VcamFileSource",
        "New-VcamVideoFilter",
        "Get-VcamObsVideoModes",
        "Select-VcamObsVideoMode",
        "Get-VcamObsSceneWarnings",
        "Test-VcamInterruptedExitCode",
        "VCAM_RESTART_ON_DISCONNECT",
        '"-pix_fmt", "yuvj420p"',
        '"-rtbufsize"',
        '"-thread_queue_size"',
        '"-fps_mode", "passthrough"',
        '"-f", "fifo"',
        '"-fifo_format", "mpjpeg"',
        '"-drop_pkts_on_overflow", "1"',
        '"-format_opts"',
        "send_buffer_size={0}",
        "tcp_nodelay=1:tcp_keepalive=1",
        "VCAM_ENCODER_THREADS",
        "VCAM_OUTPUT_QUEUE_SIZE",
        "VCAM_TCP_SEND_BUFFER_MB",
        "Get-VcamAdaptiveQueueSettings",
        '$highFPS = ConvertTo-VcamFrameRate -Value "240"',
        "jitter-driven frame duplication/drops",
        "VCAM_FFMPEG_LOG_LEVEL",
        "OBS fallback capture frame-rate self-test failed",
        "Invoke-VcamSelfTest",
        "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA",
        "Invoke-VcamObsVirtualCameraControl",
    ):
        if fragment not in windows_tool:
            fail(f"PowerShell Windows tool missing: {fragment}")
    if "$script:FpsBox.Maximum = 240" not in phone_gui:
        fail("Windows control center must expose the full 1-240 phone FPS range")

    obs_websocket_tool = read_text(control_center_path("scripts/obs-websocket.ps1"))
    for fragment in (
        "Get-VcamObsWebSocketConfig",
        "ConvertTo-VcamObsWebSocketAuthentication",
        "GetVirtualCamStatus",
        "StartVirtualCam",
        "StopVirtualCam",
        "obswebsocket.json",
        "eventSubscriptions = 0",
    ):
        if fragment not in obs_websocket_tool:
            fail(f"OBS WebSocket helper missing: {fragment}")

    preferences_controller = read_text("prefs/VCPRootListController.m")
    preferences_root = read_text("prefs/Resources/Root.plist")
    for fragment in (
        "testStreamConnection:",
        "didReceiveData:",
        "#EXTM3U",
        "VCJPEGParserConsume",
        "VCPStreamTestMaximumBytes",
        "llround",
        "notify_get_state",
    ):
        if fragment not in preferences_controller:
            fail(f"phone stream test implementation missing: {fragment}")
    if "检测当前网络流" not in preferences_root:
        fail("phone settings UI is missing the stream connection test")

    if "virtualcampro-config" not in read_text("Makefile"):
        fail("package must install the reusable phone configuration utility")
    if "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)" in read_text("Makefile"):
        fail("custom rootless staging paths must not apply the install prefix twice")
    setup_script = read_text("setup-config.sh")
    for fragment in (
        'TEMP_PREF_PATH=',
        'validate_stream_url()',
        '"--self-test"',
        'plutil -lint',
        'mv -f "$TEMP_PREF_PATH"',
    ):
        if fragment not in setup_script:
            fail(f"phone configuration utility missing atomic write guard: {fragment}")

    preferences = read_text("VCPreferences.m")
    if "MAX(1, MIN(240, preferredFPS))" not in preferences:
        fail("phone preference FPS range must remain 1-240")
    for fragment in ("candidate.user.length == 0", "candidate.fragment.length == 0"):
        if fragment not in preferences:
            fail(f"phone stream URL validation missing: {fragment}")
    root_preferences = read_plist("prefs/Resources/Root.plist") or {}
    fps_cells = [
        item for item in root_preferences.get("items", [])
        if item.get("key") == "preferredFPS"
    ]
    if len(fps_cells) != 1 or fps_cells[0].get("min") != 1 or fps_cells[0].get("max") != 240:
        fail("phone FPS slider must expose the validated 1-240 range")

    test_workflow = read_text(".github/workflows/test.yml")
    if "tests/test_jpeg_parser.c" not in test_workflow:
        fail("validation workflow must compile the standalone JPEG parser test")
    if "bash setup-config.sh --self-test" not in test_workflow:
        fail("validation workflow must exercise phone configuration validation")
    for fragment in (
        "windows-latest",
        "working-directory: VirtualCamPro-Windows-Control-Center",
        "start-stream.bat --self-test",
        "start-obs-vcam.bat --self-test",
        "install-phone.bat --self-test",
        "VirtualCamPro-Windows控制中心.bat",
        "--smoke-test",
    ):
        if fragment not in test_workflow:
            fail(f"validation workflow missing Windows tooling check: {fragment}")

    build_workflow = read_text(".github/workflows/main.yml")
    for dependency_revision in (
        "5280bd038207e14f8bd76f5417aa2fe641c03228",
        "0222fd5413cf4b9af096f37b4621afa2688572f7",
    ):
        if dependency_revision not in build_workflow:
            fail(f"build workflow has an unpinned source dependency: {dependency_revision}")
    for fragment in (
        "windows-companion:",
        "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
        "build-windows-standalone.ps1",
        "standalone-self-test.bat",
        "VirtualCamPro-Windows-Control-Center",
        "VirtualCamPro-Windows-Control-Center-2.8.0-standalone",
    ):
        if fragment not in build_workflow:
            fail(f"build workflow missing standalone artifact step: {fragment}")
    for workflow_name, workflow_text in (
        ("test.yml", test_workflow),
        ("main.yml", build_workflow),
    ):
        for action, revision in re.findall(r"uses:\s+([^@\s]+)@([^\s#]+)", workflow_text):
            if not re.fullmatch(r"[0-9a-f]{40}", revision):
                fail(f"{workflow_name} action is not pinned to an immutable SHA: {action}@{revision}")

    postinst = read_text("layout/DEBIAN/postinst")
    for fragment in ("killall mediaserverd", "killall Camera", "killall Preferences"):
        if fragment not in postinst:
            fail(f"postinst missing: {fragment}")

    postrm = read_text("layout/DEBIAN/postrm")
    for fragment in ("remove|purge", "killall mediaserverd"):
        if fragment not in postrm:
            fail(f"postrm missing: {fragment}")
    for relative in ("layout/DEBIAN/postinst", "layout/DEBIAN/postrm"):
        path = ROOT / relative
        if path.is_file() and b"\r\n" in path.read_bytes():
            fail(f"maintainer script uses CRLF line endings: {relative}")


def validate_documentation() -> None:
    documentation_paths = list(ROOT.glob("*.md"))
    documentation_paths.extend((ROOT / CONTROL_CENTER).glob("*.md"))
    for path in documentation_paths:
        text = path.read_text(encoding="utf-8")
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
            if target.startswith(("http://", "https://", "#")):
                continue
            local_target = target.split("#", 1)[0]
            if local_target and not (path.parent / local_target).exists():
                fail(f"broken local link in {path.name}: {target}")

    readme = read_text("README.md")
    for document in (
        "BUILD_INSTRUCTIONS.md",
        "ARCHITECTURE.md",
        "STREAMING.md",
        "VirtualCamPro-Windows-Control-Center/DEPLOYMENT.md",
        "VirtualCamPro-Windows-Control-Center/WINDOWS_TOOLS.md",
        "TROUBLESHOOTING.md",
        "DEVICE_TEST_PLAN.md",
        "CHANGELOG.md",
    ):
        if f"]({document})" not in readme:
            fail(f"README does not link to {document}")

    build_instructions = read_text("BUILD_INSTRUCTIONS.md")
    for fragment in (
        "install-phone.bat --check PHONE_IP",
        "install-phone.bat PHONE_IP",
        "ssh mobile@PHONE_IP",
        "sudo -v",
        "sudo dpkg -i",
    ):
        if fragment not in build_instructions:
            fail(f"rootless installation documentation missing: {fragment}")
    if "ssh root@PHONE_IP" in build_instructions:
        fail("rootless installation documentation must not require direct root SSH")

    device_plan = read_text("DEVICE_TEST_PLAN.md")
    for mode in (
        "Live Photo",
        "连拍",
        "人像",
        "全景",
        "4K30",
        "慢动作",
        "延时摄影",
        "AVCaptureMovieFileOutput",
        "getUserMedia",
    ):
        if mode not in device_plan:
            fail(f"device test plan missing camera mode: {mode}")


def main() -> int:
    validate_plists()
    validate_makefile()
    validate_preferences()
    validate_filters()
    validate_package()
    validate_sources()
    validate_documentation()
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("VirtualCamPro project validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
