@rem VirtualCamPro Windows launcher configuration.
@rem Edit only the values after the equals signs. Empty paths are auto-detected.

@rem Optional exact executable paths.
set "VCAM_FFMPEG_PATH="
set "VCAM_OBS_PATH="

@rem Optional OBS scene. Leave blank to keep the saved scene.
set "VCAM_OBS_SCENE="

@rem auto reads the current saved OBS profile on launcher start and OBS reconnect.
@rem Explicit alternatives: landscape or portrait; 720p, 1080p, 1440p, or 2160p.
set "VCAM_ORIENTATION=landscape"
set "VCAM_RESOLUTION=auto"
@rem Accepts 1-240, including 23.976, 59.94, 120, 240, or rational expressions.
@rem OBS must publish the same rate; restart Virtual Camera after changing OBS Video settings.
set "VCAM_FPS=auto"

@rem fill crops the edges to remove bars; fit preserves the whole source; stretch distorts it.
set "VCAM_SCALE_MODE=fill"

@rem FFmpeg MJPEG quality from 1 through 31. Lower is clearer and uses more bandwidth.
@rem Quality 1 is the maximum encoder quality; use a larger number only by choice.
set "VCAM_QUALITY=1"

@rem HTTP listener. 0.0.0.0 exposes it on all IPv4 network adapters.
set "VCAM_BIND_ADDRESS=0.0.0.0"
set "VCAM_PORT=8888"

@rem Startup and recovery behavior.
set "VCAM_OBS_WAIT_SECONDS=15"
set "VCAM_RESTART_ON_DISCONNECT=true"

@rem Buffer floors. High resolution/FPS modes scale raw/input/network queues
@rem automatically without changing FPS, resolution, or quality.
set "VCAM_RT_BUFFER_MB=256"
set "VCAM_THREAD_QUEUE_SIZE=32"

@rem Parallel JPEG encoding plus bounded encoded/TCP buffers prevents a short
@rem Wi-Fi stall from blocking DirectShow capture. Sustained overflow discards
@rem only packets that can no longer be delivered in real time.
set "VCAM_ENCODER_THREADS=4"
set "VCAM_OUTPUT_QUEUE_SIZE=64"
set "VCAM_TCP_SEND_BUFFER_MB=4"

@rem error keeps the GUI concise; use warning or info for deeper FFmpeg diagnostics.
set "VCAM_FFMPEG_LOG_LEVEL=error"

@rem Refuse to silently upscale a stale or low-resolution OBS Virtual Camera mode.
set "VCAM_REQUIRE_OBS_MODE_MATCH=true"

@rem When OBS is already running, use its password-protected local WebSocket API to
@rem start or safely refresh only Virtual Camera. OBS itself is never force-closed.
set "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA=true"

@rem Change only if FFmpeg lists the OBS virtual camera under another exact name.
set "VCAM_DEVICE_NAME=OBS Virtual Camera"
