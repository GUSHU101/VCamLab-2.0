#!/usr/bin/env python3
"""Repository checks that do not require Theos or an iOS SDK."""

from __future__ import annotations

import plistlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ERRORS: list[str] = []


def fail(message: str) -> None:
    ERRORS.append(message)


def read_text(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing file: {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def read_plist(relative: str):
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing plist: {relative}")
        return {}
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception as exc:
        fail(f"invalid plist {relative}: {exc}")
        return {}


def require(text: str, fragments: tuple[str, ...], context: str) -> None:
    for fragment in fragments:
        if fragment not in text:
            fail(f"{context} missing: {fragment}")


def validate_plists() -> None:
    for path in sorted(ROOT.rglob("*.plist")):
        try:
            with path.open("rb") as handle:
                plistlib.load(handle)
        except Exception as exc:
            fail(f"invalid plist {path.relative_to(ROOT)}: {exc}")


def validate_makefile() -> None:
    makefile = read_text("Makefile")
    require(
        makefile,
        (
            "THEOS_PACKAGE_SCHEME = rootless",
            "TARGET = iphone:clang:16.5:15.0",
            "ARCHS ?= arm64 arm64e",
            "TWEAK_NAME = AVFCameraSupport VCMediaServer",
            "VCSharedMediaBus.m",
            "VCAudioSampleConverter.m",
            "VCScreenCaptureSource.m",
            "VCLocalMediaSource.m",
            "IOSurface",
            "AudioToolbox",
            "INSTALL_TARGET_PROCESSES = SpringBoard Camera mediaserverd",
        ),
        "Makefile",
    )
    source_names = set(
        re.findall(r"[A-Za-z0-9_+.-]+\.(?:m|mm|x|xm|c|cpp)(?![A-Za-z0-9_.-])", makefile)
    )
    for source in source_names:
        if not (ROOT / source).is_file():
            fail(f"Makefile references missing source: {source}")
    media_frameworks = re.search(r"^VCMediaServer_FRAMEWORKS\s*=\s*(.+)$",
                                 makefile,
                                 re.MULTILINE)
    if media_frameworks and "UIKit" in media_frameworks.group(1).split():
        fail("mediaserverd binary must not statically link UIKit")


def validate_preferences() -> None:
    implementation = read_text("VCPreferences.m")
    header = read_text("VCPreferences.h")
    root = read_plist("prefs/Resources/Root.plist")
    keyed = {item.get("key"): item for item in root.get("items", []) if item.get("key")}
    expected = {
        "enabled",
        "sourceType",
        "streamURL",
        "localMediaPath",
        "loopLocalMedia",
        "preferredFPS",
        "sourceRotation",
        "mirrorSource",
        "maximumPixelDimension",
        "jpegQuality",
        "aspectFill",
        "holdLastFrame",
        "staleFrameTimeout",
    }
    missing = expected - keyed.keys()
    if missing:
        fail(f"settings UI missing keys: {', '.join(sorted(missing))}")
    for key in expected:
        item = keyed.get(key, {})
        if item.get("defaults") != "com.murkaska.virtualcampro":
            fail(f"wrong preference domain for {key}")
        if item.get("PostNotification") != "com.murkaska.virtualcampro/preferences.changed":
            fail(f"missing Darwin preference notification for {key}")
        if f'@"{key}"' not in implementation:
            fail(f"VCPreferences.m missing key constant: {key}")
    if keyed.get("sourceType", {}).get("validValues") != [0, 1, 2]:
        fail("sourceType must expose network, screen, and local media")
    if keyed.get("enabled", {}).get("default") is not False:
        fail("replacement must remain disabled by default")
    if keyed.get("loopLocalMedia", {}).get("default") is not True:
        fail("local media should loop by default")
    for key in (
        "localMediaPath",
        "loopLocalMedia",
        "preferredFPS",
        "sourceRotation",
        "mirrorSource",
        "maximumPixelDimension",
        "jpegQuality",
        "aspectFill",
    ):
        if keyed.get(key, {}).get("vcSourceTypes") != [2]:
            fail(f"{key} must be presented as a local-media-only setting")
    if "compatibilityMode" in keyed or "VCCompatibilityModeKey" in header:
        fail("the obsolete manual compatibility mode is still exposed")
    require(
        implementation,
        (
            'hasPrefix:@"/var/mobile/Media/"',
            'hasPrefix:@"/var/mobile/Library/VirtualCamPro/"',
            "path.stringByStandardizingPath",
            "candidate.user.length == 0",
            "candidate.password.length == 0",
        ),
        "preference validation",
    )
    example = read_plist("example-config.plist")
    for key in expected:
        if key not in example:
            fail(f"example-config.plist missing key: {key}")


def validate_injection_filters() -> None:
    app_filter = read_plist("AVFCameraSupport.plist").get("Filter", {})
    expected_classes = {
        "AVCaptureVideoDataOutput",
        "AVCaptureAudioDataOutput",
        "AVCaptureVideoPreviewLayer",
        "AVCapturePhoto",
    }
    if set(app_filter.get("Classes", [])) != expected_classes:
        fail("application injection filter must remain AVFoundation-specific")
    if set(app_filter.get("Bundles", [])) != {
        "com.apple.UIKit",
        "com.apple.UIKitCore",
        "com.apple.WebKit.WebContent",
    }:
        fail("application injection filter is broader than the reviewed scope")
    system_executables = read_plist("VCMediaServer.plist").get("Filter", {}).get(
        "Executables", []
    )
    if system_executables != ["mediaserverd", "SpringBoard"]:
        fail("system binary must inject only into mediaserverd and SpringBoard")


def validate_zero_copy_bus() -> None:
    header = read_text("VCSharedMediaBus.h")
    protocol = read_text("VCSharedMediaProtocol.h")
    bus = read_text("VCSharedMediaBus.m")
    screen = read_text("VCScreenCaptureSource.m")
    local = read_text("VCLocalMediaSource.m")
    network = read_text("AVAssetStreamAdapter.m")
    network_header = read_text("AVAssetStreamAdapter.h")
    coordinator = read_text("VCStreamCoordinator.m")
    require(
        header + protocol + bus,
        (
            "VC_SHARED_VIDEO_RING_SIZE 3u",
            "VCPackSurfaceState",
            "VCRequiredCanonicalInputFrames",
            "VCResolveAudioReadStart",
            "IOSurfaceGetID",
            "IOSurfaceLookup",
            "CVPixelBufferCreateWithIOSurface",
            "kIOSurfaceIsGlobal",
            "mach_continuous_time",
            "totalFramesWritten",
            "memory_order_release",
            "VCMarkSystemPipelineActivity",
            "VCSystemPipelineIsActive",
            "_cachedSurfaceState",
            "_cachedPixelBuffer",
            "IOSurfaceIncrementUseCount",
            "IOSurfaceDecrementUseCount",
            "VCReleaseSharedVideoPixelBuffer",
        ),
        "shared media bus",
    )
    if "NSData" in bus or "NSKeyedArchiver" in bus:
        fail("shared frame bus must not serialize media payloads")
    require(
        screen,
        (
            'dlsym(RTLD_DEFAULT,',
            '"CARenderServerRenderDisplay"',
            "CVPixelBufferPoolCreatePixelBufferWithAuxAttributes",
            "kIOSurfaceIsGlobal",
            "if (!self.renderDisplay)",
        ),
        "screen producer",
    )
    require(
        local,
        (
            "AVAssetReader",
            "AVAssetReaderTrackOutput",
            "AVSampleRateKey: @48000",
            "AVNumberOfChannelsKey: @2",
            "alwaysCopiesSampleData = NO",
            "CMTimeCompare",
            "maximumPixelDimension",
            "preferredFPS",
            "BOOL tooLate",
            "CMBlockBufferGetDataPointer",
        ),
        "local media producer",
    )
    require(
        coordinator,
        (
            'isEqualToString:@"SpringBoard"',
            "stopAllSourcesAndInvalidateBus",
            "publishPixelBuffer:transformed",
            "publishInterleavedStereoSamples",
            "_pendingPixelBuffer",
            "_frameProcessingScheduled",
        ),
        "single-producer coordinator",
    )
    if "initWithURL:" in coordinator.split("if (!_producerProcess) return;", 1)[0]:
        fail("a consumer path can still instantiate a network decoder")
    require(
        network,
        (
            "CGImageSourceCreateImageAtIndex",
            "_pendingMJPEGData",
            "mjpegDecodeQueue",
            "decodePendingMJPEGFrames",
            "VCMJPEGDecompressionOutputCallback",
            "VTDecompressionSessionDecodeFrame",
            "kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder",
            "kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder",
            "copyPixelBufferFromJPEGDataUsingImageIO",
            "_mjpegSupersededFrameCount",
            "average-decode=%.2fms",
            "VCHLSPollingFPS = 240",
            "preferredForwardBufferDuration = 0.25",
            "catchUpToHLSLiveEdgeIfNeeded",
        ),
        "sender-authoritative network decoder",
    )
    if "CGImageSourceCreateThumbnail" in network:
        fail("network MJPEG must not apply a phone-side thumbnail quality/orientation transform")
    if "preferredFPS" in network_header or "maximumPixelDimension" in network_header:
        fail("network decoder still exposes phone-side FPS or quality controls")
    if "self.networkSource.preferredFPS" in coordinator or \
       "self.networkSource.maximumPixelDimension" in coordinator:
        fail("coordinator still applies local FPS/quality settings to a network source")
    require(
        coordinator,
        (
            "localMediaControlsActive = sourceType == VCSourceTypeLocalMedia",
            "effectiveRotation = localMediaControlsActive ? rotation : 0",
            "effectiveMirror = localMediaControlsActive ? mirror : NO",
            "VCLocalVideoPlaylistForURL",
            "handleLocalMediaVolumeButtonDirection",
        ),
        "source-specific media policy",
    )


def validate_hooks_and_fail_open() -> None:
    media = read_text("MediaServer.x")
    tweak = read_text("Tweak.x")
    audio = read_text("VCAudioSampleConverter.m")
    converter = read_text("VCFrameConverter.m")
    all_source = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for pattern in ("*.m", "*.h", "*.x", "*.xm")
        for path in ROOT.glob(pattern)
    )
    banned = {
        "device identity spoofing": r"%hook\s+AVCaptureDevice\b",
        "Apple bundle identity spoofing": r"setBundleIdentifier|com\.apple\.[^\"\s]+\s*=",
        "anti-debugging or jailbreak hiding": r"P_TRACED|ptrace\s*\(|/Applications/Cydia\.app",
    }
    for label, pattern in banned.items():
        if re.search(pattern, all_source):
            fail(f"unexpected {label} code")
    require(
        media,
        (
            "VCMethodAcceptsSampleBuffer",
            "VCMethodReturnsBoolean",
            "objc_getClassList",
            "VCClassIsSubclassOfClass",
            "VCDirectInstanceMethod",
            "VCMediaServerRescanScheduled",
            "VCReplacedSampleAttachmentKey",
            "CMSampleBufferGetImageBuffer",
            "CMAudioFormatDescriptionGetStreamBasicDescription",
            "VCIsSupportedReplacementPixelFormat",
            "replacement ?: originalBuffer",
            "Depth, disparity, metadata and compressed auxiliary streams",
            "VCMarkSystemPipelineActivity(VCSharedMediaKindVideo)",
            "VCMarkSystemPipelineActivity(VCSharedMediaKindAudio)",
            "VCInstallSpringBoardVolumeHooks",
            "SBVolumeControl",
            "handleLocalMediaVolumeButtonDirection:1",
            "handleLocalMediaVolumeButtonDirection:-1",
        ),
        "system hook fail-open path",
    )
    require(
        tweak,
        (
            "VCVideoDataOutputProxy",
            "VCAudioDataOutputProxy",
            "VCSystemPipelineIsActive",
            "replacement ?: sampleBuffer",
            "VCPhotoDataPreservesAuthenticMetadata",
            "preserving the authentic original camera file",
            "semanticSegmentationMatteForType",
            "portraitEffectsMatte",
            "depthData",
            "VCCopyStablePixelBuffer",
            "replaceSharedPixelBufferLease",
            "VCReleaseSharedVideoPixelBuffer",
        ),
        "application fallback",
    )
    springboard_guard = tweak.find('isEqualToString:@"SpringBoard"')
    springboard_return = tweak.find("return;", springboard_guard)
    if springboard_guard < 0 or springboard_return < 0:
        fail("application binary must stay inert when class filters select SpringBoard")
    require(
        audio,
        (
            "kAudioFormatLinearPCM",
            "outputFrameCount",
            "CMSampleBufferGetPresentationTimeStamp",
            "CMAudioSampleBufferCreateWithPacketDescriptions",
            "CMSampleBufferSetDataBufferFromAudioBufferList",
            "CMSampleBufferSetDataReady",
            "kAudioFormatFlagIsNonInterleaved",
            "sampleStride",
            "CMSampleBufferGetSampleAttachmentsArray",
            "return NULL",
        ),
        "audio format preservation",
    )
    require(
        converter,
        (
            "CMVideoFormatDescriptionMatchesImageBuffer",
            "VTPixelTransferSessionTransferImage",
            "CMSampleBufferGetSampleAttachmentsArray",
            "VCIsSupportedReplacementPixelFormat",
            "VCMaximumOutstandingBuffersPerFormat = 6",
            "VCCopyStablePixelBuffer",
        ),
        "video format preservation",
    )


def validate_package_and_docs() -> None:
    control = read_text("control")
    require(
        control,
        (
            "Package: com.murkaska.virtualcampro",
            "Architecture: iphoneos-arm64",
            "firmware (>= 15.0)",
            "firmware (<< 16.0)",
        ),
        "Debian control",
    )
    version_match = re.search(r"(?m)^Version: ([0-9][0-9A-Za-z.+:~_-]*)$", control)
    if not version_match:
        fail("Debian control has no valid Version field")
        package_version = ""
    else:
        package_version = version_match.group(1)
    apple_relationship = re.search(
        r"(?mi)^(?:Provides|Replaces|Conflicts):\s*[^\n]*\bcom\.apple\.",
        control,
    )
    if apple_relationship:
        fail("package must not impersonate, replace, or conflict with an Apple package")

    preferences_info = read_plist("prefs/Info.plist")
    preferences_makefile = read_text("prefs/Makefile")
    if "VirtualCamPro_BUNDLE_RESOURCE_FILES = Info.plist" not in preferences_makefile:
        fail("preference bundle must explicitly package its Info.plist")
    if package_version:
        if preferences_info.get("CFBundleShortVersionString") != package_version or \
           preferences_info.get("CFBundleVersion") != package_version:
            fail("preference bundle version does not match Debian package version")
        readme = read_text("README.md")
        changelog = read_text("CHANGELOG.md")
        if f"当前版本：`{package_version}`" not in readme:
            fail("README current version does not match Debian package version")
        if f"## {package_version}" not in changelog:
            fail("CHANGELOG has no section for the Debian package version")

    for relative in (
        "layout/DEBIAN/postinst",
        "layout/DEBIAN/postrm",
        "setup-config.sh",
        "scripts/verify_deb.sh",
    ):
        path = ROOT / relative
        if not path.is_file():
            fail(f"missing package script: {relative}")
        elif b"\r\n" in path.read_bytes():
            fail(f"package script must use LF line endings: {relative}")
    for path in list(ROOT.glob("*.md")) + list(
        (ROOT / "VirtualCamPro-Windows-Control-Center").glob("*.md")
    ):
        text = path.read_text(encoding="utf-8")
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
            if target.startswith(("http://", "https://", "#")):
                continue
            local = target.split("#", 1)[0]
            if local and not (path.parent / local).exists():
                fail(f"broken local link in {path.name}: {target}")

    windows_config = read_text("VirtualCamPro-Windows-Control-Center/obs-vcam-config.cmd")
    require(
        windows_config,
        (
            'VCAM_HLS_SEGMENT_SECONDS=0.25',
            'VCAM_HLS_LIST_SIZE=6',
            'VCAM_HLS_PRESET=ultrafast',
            'VCAM_HLS_BUFSIZE_KBPS=12000',
            'VCAM_RT_BUFFER_MB=64',
            'VCAM_THREAD_QUEUE_SIZE=4',
            'VCAM_OUTPUT_QUEUE_SIZE=3',
            'VCAM_TCP_SEND_BUFFER_MB=1',
        ),
        "Windows low-latency defaults",
    )

    manifest_path = ROOT / "VirtualCamPro-Windows-Control-Center/standalone-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as error:
        fail(f"invalid standalone manifest: {error}")
        manifest = {}
    if manifest.get("toolVersion") != package_version:
        fail("Windows companion and iOS package versions do not match")
    if manifest.get("packageIncluded") is not False:
        fail("source-tree standalone manifest must not advertise a stale bundled package")

    package_verifier = read_text("scripts/verify_deb.sh")
    require(
        package_verifier,
        (
            "dpkg-deb -f",
            "actual_version",
            "actual_architecture",
            "AVFCameraSupport.dylib",
            "VCMediaServer.dylib",
            "virtualcampro-config",
            "plistlib.load",
            "sha256sum",
        ),
        "built package verifier",
    )


def validate_jpeg_parser_tests() -> None:
    test = read_text("tests/test_jpeg_parser.c")
    require(
        test,
        (
            "testIncrementalBaselineAndEmbeddedThumbnail",
            "testProgressiveScans",
            "testInvalidStructure",
            "testConcatenatedFramesReturnOneFrameAtATime",
            "testMarkerSplitAcrossCallbacks",
            "testFrameDimensionsSurviveIncrementalParsing",
            "testInvalidFrameDimensions",
        ),
        "JPEG parser tests",
    )
    shared_test = read_text("tests/test_shared_media_protocol.c")
    require(
        shared_test,
        (
            "testSurfaceStateRoundTrip",
            "testAudioRingWrap",
            "testAudioReadCursor",
            "testResampleInputBounds",
        ),
        "shared media protocol tests",
    )


def validate_workflows() -> None:
    workflow_paths = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    if not workflow_paths:
        fail("no GitHub Actions workflows found")
        return
    combined = ""
    for path in workflow_paths:
        text = path.read_text(encoding="utf-8")
        combined += text
        for action, revision in re.findall(r"uses:\s+([^@\s]+)@([^\s#]+)", text):
            if not re.fullmatch(r"[0-9a-f]{40}", revision):
                fail(f"workflow action is not pinned: {action}@{revision}")
    require(
        combined,
        (
            "tests/test_jpeg_parser.c",
            "tests/test_shared_media_protocol.c",
            "make package FINALPACKAGE=1",
            "scripts/verify_deb.sh",
            "dpkg-deb -f",
            "-fsanitize=address,undefined",
            "tools/build-windows-standalone.ps1",
            "persist-credentials: false",
            "cancel-in-progress: true",
            "5280bd038207e14f8bd76f5417aa2fe641c03228",
            "0222fd5413cf4b9af096f37b4621afa2688572f7",
            "a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e",
            "sha256sum --check --strict",
            "toolchain/linux/iphone/bin/clang",
        ),
        "CI workflows",
    )


def main() -> int:
    validate_plists()
    validate_makefile()
    validate_preferences()
    validate_injection_filters()
    validate_zero_copy_bus()
    validate_hooks_and_fail_open()
    validate_package_and_docs()
    validate_jpeg_parser_tests()
    validate_workflows()
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("VirtualCamPro unified-pipeline validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
