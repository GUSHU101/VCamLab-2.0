# Changelog

## Unreleased

- Consolidated the ready-to-run Windows control center, official Rootless package, integrity manifest, and current deployment guide under `VirtualCamPro-Windows-Control-Center/`; removed duplicate root launchers and obsolete local build debris.
- Made the package-free Windows GUI path safe on clean machines, preserved PowerShell test failures through the CMD launcher, and switched the CI staging directory to an artifact-uploader-safe ASCII name.
- Decoupled DirectShow capture from slow HTTP clients with adaptive buffering (256 MiB/32-frame/64-frame floors), four-thread MJPEG encoding, an encoded FIFO, and a 4 MiB low-latency TCP buffer, without reducing configured FPS or JPEG quality.
- Made compatibility-mode preview display the exact converted application output frame, and made photo preview, pixel-buffer, CGImage, and file representations share one atomic source-frame snapshot.
- Unified installer, preferences, decoder, preview, and sample-timing defaults at a stable 60 FPS baseline instead of silently retaining legacy 30 FPS defaults.
- Bypassed the Lanczos scale/crop stage when OBS already publishes the exact canvas, preserving source pixels while reducing filter CPU load at 1080p60 and above.
- Reworked the 60 FPS MJPEG receive hot path around a forward cursor and 1 MiB batched compaction instead of shifting the buffer after every frame, while retaining the 24/32 MiB frame and receive safety limits.
- Serialized MJPEG parser/pool teardown across reconnects and memory-pressure callbacks, revalidated the active session before frame delivery, and raised the bounded decode-pool allowance to six buffers to prevent transient fail-open flashes during photo/preview fan-out.
- Added read-back verification for replacement dimensions and authentic TIFF/EXIF/GPS/Apple metadata, including exact Apple maker-dictionary equality, and removed the metadata-free UIKit JPEG fallback; an unverifiable replacement now preserves the original camera file.
- Stopped attaching or exposing depth, disparity, portrait/semantic mattes, HDR gain maps, or secondary images from the physical scene to a different network image; authentic device metadata is preserved without internally contradictory scene payloads.
- Made the Settings stream test use the production incremental JPEG parser instead of raw SOI/EOI byte searches, and append receive chunks without temporary `NSData` copies.
- Pinned all GitHub Actions dependencies to the verified current release commit SHAs and made project validation reject floating CI action references.
- Pinned the Theos and iPhoneOS 16.5 SDK source commits used by packaging, eliminating two remaining floating build inputs.
- Aligned the installed `virtualcampro-config` URL checks with runtime rules (scheme, host, credentials, fragments, whitespace, and length) and added a non-mutating configuration self-test to both CI workflows.
- Serialized and cached the complete `AVCapturePhoto` file representation, including authentic-original fallback results, so repeated or concurrent client reads cannot re-encode different data.
- Gated every photo rewrite on a proven replacement frame: compatibility mode requires an atomic network snapshot, while system mode requires a receiving/holding status from `mediaserverd`; disabled, startup, and fail-open photos now remain byte-for-byte on the original API path.
- Added an explicit cross-process “holding last replacement frame” status so photo consistency and Settings diagnostics remain accurate while the network reconnects.
- Invalidated cross-process “receiving” state whenever critical memory pressure or a source transform clears the latest frame, preventing a concurrent photo from being misclassified as replaced.
- Moved high-rate HLS pixel-buffer polling from the UI main queue to a user-interactive serial queue while keeping AVPlayer setup/teardown on the main thread.
- Added a PowerShell 5.1 WinForms control center for visual phone preflight, package selection, custom phone FPS, one-click installation/configuration, live status logs, and installed runtime verification.
- Integrated `start-obs-vcam.bat` into the control center with direct bridge start, bridge diagnostics, and optional automatic start after successful phone deployment.
- Added an optional non-secret installer event log and a read-only Verify mode while keeping all SSH and sudo passwords inside the native OpenSSH terminal.
- Fixed remote verification under the default iOS zsh by avoiding its read-only `status` parameter.
- Added end-to-end uploaded-package SHA-256 verification, failure-path upload cleanup, SSH keepalives, and URL query-token redaction from Windows logs.
- Made OBS preflight fail with exit code 5 when the requested DirectShow mode is unavailable, while preserving a safe permissive-mode capture fallback for genuinely different rates.
- Added a reproducible Windows standalone builder, immutable-file manifest verification, complete CLI launchers, and an aggregate offline self-test.
- Bounded orientation pixel-buffer allocation, tightened phone URL validation, normalized the settings FPS slider to integers, and required a complete JPEG during the in-phone stream test.
- Expanded incremental JPEG parser regression coverage for concatenated frames, split markers, missing SOI, and invalid segment lengths.
- Hardened the standalone control center's mutable CMD configuration with a strict variable whitelist, command-metacharacter rejection, verify-before-load launchers, and rejection of every unmanifested payload.
- Made package-free standalone builds explicit in their signed manifest contract, so an upgraded Windows control center can be distributed without silently bundling a stale iOS package.
- Rejected links, reparse points, and all unmanifested files during standalone verification, closing path-redirection and side-load gaps around the hashed payload.
- Froze the replacement route once per `AVCapturePhoto` (original, compatibility, or system pipeline), preventing network-state changes from making pixels, file data, depth, and mattes disagree for the same capture.
- Deferred compatibility-preview BGRA conversion until a preview layer actually renders, eliminating an unnecessary per-frame GPU pass in headless recording and processing clients.
- Removed the legacy 60 FPS software ceiling across OBS profile parsing, Windows overrides, deployment tools, preferences, MJPEG, and HLS; explicit rates up to 240 FPS are accepted only when the real producer/consumer path supports them, and Windows queues scale to retain roughly half a second of capture plus one second of encoded burst capacity.
- Made DirectShow `rtbufsize` resolution/FPS-aware: 256 MiB remains the floor, while high-bandwidth modes scale toward half a second of raw buffering up to 1 GiB without changing their output mode.
- Removed the FFmpeg `fps` filter from exact OBS/DirectShow modes, preserving capture timestamps without jitter-driven duplication or drops; rate conversion remains only for file sources and explicitly permissive mismatched fallbacks.
- Raised replacement-photo JPEG fallback quality to the quality-scale maximum (`1.0`) while retaining read-back metadata verification and authentic-original failover.
- Raised the Windows MJPEG default from quality 5 to encoder-maximum quality 1 after a local 1080p60 stress run completed at roughly 17× real time; users may still choose a larger qscale explicitly, but no automatic quality reduction exists.

## 2.8.0

- Added a latest-frame-wins phone processing queue that coalesces pending frames before GPU orientation/conversion, preventing load spikes from turning into steadily increasing latency.
- Changed bursty MJPEG handling to discard completed backlog frames and decode the newest complete JPEG available in each network callback.
- Added an in-phone stream test that reads live `mediaserverd` receive/reconnect state without stealing the single MJPEG connection, and verifies HTTP/content/JPEG/HLS data directly when the system pipeline is inactive.
- Added authenticated OBS WebSocket 5 control for safely starting or refreshing only Virtual Camera when OBS is already running, without terminating OBS or losing unsaved scenes; the launcher degrades to a precise one-time action when the server is disabled.
- Added `install-phone.bat --setup`, which installs the package, derives the correct computer-side LAN address, writes the stream URL/FPS to the phone, and notifies the running plugin.
- Hardened phone installation with upload-size validation, exact installed-version verification, successful-upload cleanup, and an atomically written packaged `virtualcampro-config` utility.
- Reused the Core Image orientation color space and expanded static/Windows self-tests to cover the new recovery, installation, and low-latency paths.

## 2.7.0

- Read the current saved OBS profile automatically on every launcher start and OBS reconnect, including base canvas, scaled output, and common/integer/fractional FPS formats.
- Made OBS resolution and FPS automatic by default while retaining explicit command-line and environment overrides.
- Cross-checked saved OBS settings against the DirectShow mode actually published by Virtual Camera so stale live state cannot silently override a newly saved profile.
- Added safe OBS INI parsing, current-profile resolution, path validation, and offline regression coverage.

## 2.6.0

- Accepted custom Windows rates from 1 through 60 FPS as integers, decimals, or rational expressions such as `30000/1001`, with locale-independent FFmpeg arguments.
- Tightened OBS mode matching to distinguish fractional NTSC rates such as 29.97/59.94 from 30/60 while tolerating harmless driver reporting noise.
- Added one-command FPS overrides to the OBS launcher and validated optional phone FPS configuration in `setup-config.sh`.
- Expanded the phone decode/preview cap from 15–60 to 1–60 FPS and included the active cap in first-frame diagnostics.

## 2.5.0

- Required an exact OBS DirectShow resolution/FPS match before streaming, explicitly selected the advertised input mode, and reduced the real-time/thread queues so stale frames are dropped instead of accumulating hundreds of megabytes of latency.
- Added `fill`, `fit`, and `stretch` output geometry modes, defaulted to 1080p30 quality 5, and diagnosed visible OBS image sources that still use non-adaptive free transforms.
- Recognized Windows interrupt exit codes so a normal `Ctrl+C` / FFmpeg `Immediate exit requested` shutdown does not enter the disconnect-recovery loop.
- Preserved original EXIF/GPS/TIFF properties in an ImageIO JPEG fallback when the source photo container cannot be safely rewritten, with explicit rate-limited diagnostics before the final metadata-free UIKit fallback.
- Included the WebKit content process in the application compatibility filter while retaining the existing non-spoofing device model: browsers still enumerate the built-in iPhone cameras whose frames are replaced.

- Added independent preference, stream, and transform generations so stale asynchronous frames cannot overwrite a newly selected URL or orientation.
- Replaced repeated whole-buffer MJPEG end-marker scans with an incremental JPEG marker/segment parser that correctly skips embedded JPEG data in metadata segments.
- Bounded MJPEG frames at 24 MiB and the receive buffer at 32 MiB, rejected obvious non-image responses early, and rate-limited malformed-stream diagnostics.
- Reused the MJPEG RGB color space, reduced inactive preview polling to 1 FPS, and cached rewritten photo data for repeated access.
- Reused semantically equal camera format descriptions and raised the bounded per-format in-flight buffer allowance from four to six to reduce fail-open flashes under pipeline fan-out.
- Rebuilt the Windows launchers around a PowerShell 5.1 core with strict typed configuration, port-owner and LAN URL diagnostics, OBS DirectShow frame probing, ffprobe input validation, yuvj420p output, disconnect recovery, bounded failure retries, and Windows CI self-tests.
- Added a password-safe Windows rootless phone preflight and installer that validates SSH, real `sudo` elevation, `dpkg`, package naming and SHA-256 before SCP installation and final package-state verification.
- Corrected rootless installation, emergency-disable, and removal documentation to use `mobile + sudo`, with explicit recovery guidance for inactive jailbreak or `nosuid` failures.

## 2.4.0

- Added one-pass GPU source orientation normalization with 0/90/180/270-degree rotation and optional horizontal mirroring before fan-out to camera outputs.
- Added validated MJPEG decode limits for 1280, 1920, 2560, and experimental 3840-pixel sources, defaulting to 1920 for the A10 device profile.
- Reused the normalized source frame across preview, photo, video, browser, and third-party camera paths instead of rotating every downstream output.
- Cleared stale oriented frames immediately when orientation preferences change and retained fail-open behavior when GPU rendering is unavailable.
- Upgraded the Windows MJPEG launcher to 1080p by default with 720p/1080p/1440p/2160p presets, Lanczos scaling, configurable MJPEG quality, and lower-latency packet flushing.
- Expanded OBS instructions for scene rotation, media pause/resume, hotkeys, and quality/performance tuning.

## 2.3.0

- Removed the application-layer startup race by installing a pass-through video delegate proxy independently of current stream readiness.
- Made preview fallback layers react to preference changes without requiring them to exist only after the stream becomes active.
- Regenerated cached photo buffers when the full-resolution or preview template changes dimensions or pixel format.
- Preserved the original photo container, metadata, secondary images, depth/disparity, portrait matte, semantic mattes, and HDR gain-map payloads when ImageIO can rewrite the format.
- Kept original audio, depth, disparity, metadata, and unsupported image formats on the fail-open path.
- Expanded the iPhone 7 Plus validation matrix across photo, Live Photo, portrait, panorama, burst, video, slow motion, time lapse, third-party capture, and browser capture.

## 2.2.0

- Added runtime-validated `mediaTypeIsVideo` filtering and a supported color-format allowlist before frame replacement.
- Replaced per-frame string/dictionary cache keys with bounded C-structure caches and LRU pixel-buffer pools.
- Added format-description identity to converted-frame cache keys so outputs with different color/aperture extensions cannot share incompatible attachments.
- Reused the original camera format description only after `CMVideoFormatDescriptionMatchesImageBuffer` succeeds, with safe regeneration and per-output caching otherwise.
- Added pixel-buffer allocation thresholds and dispatch memory-pressure handling that tears down recyclable buffers and VideoToolbox state.
- Replaced the coordinator's per-frame `@synchronized` monitor with short `os_unfair_lock` critical sections and releases outside the lock.
- Added stricter sample width, height, subtype, and format-description consistency checks with fail-open behavior.

## 2.1.0

- Added a first-frame/stalled-frame watchdog for HLS and MJPEG connections.
- Added configurable last-frame retention and stale-frame timeout behavior.
- Cached converted camera buffers for repeated `BWNodeOutput` formats.
- Added MJPEG decode throttling, 1920-pixel bounded thumbnail decoding, and reusable pixel-buffer pools.
- Reduced compatibility-mode overhead when the system pipeline is selected.
- Added runtime method-signature validation before installing the private camera hook.
- Added portrait/landscape modes to the Windows MJPEG launcher.
- Added package install/removal scripts that reload affected system processes.
- Restricted the package to the validated iOS 15 release family.

## 2.0.0

- Replaced the overlay-only design with a default `mediaserverd` frame-replacement path.
- Added an application-layer compatibility path for video data, preview, and photos.
- Rebuilt HLS/MJPEG reception, preferences, rootless packaging, documentation, and CI validation.
- Removed device capability spoofing, authorization bypass, jailbreak hiding, and anti-debugging code.
