# Hand Vision Native

Lightweight macOS hand tracking prototype built with Swift, AVFoundation, and
Apple Vision. It is isolated from the existing Electron tracker and emits the
same OSC address and argument layout, with `z = 0` for all landmarks.

The app is a menu-bar utility with a compact settings window and an
`AVCaptureVideoPreviewLayer` camera preview. The preview reflects centered zoom
and rotation, with all 21 joints and the MediaPipe hand skeleton overlaid in a
different color for each hand. It detaches from the capture session whenever
the window is closed, minimized, hidden, or fully occluded so tracking from the
menu bar adds no hidden preview or overlay work.

## Requirements

- macOS 13 or later
- A Mac with a camera supported by AVFoundation
- Swift 5.9 or later (`xcode-select --install` is sufficient; no Xcode project
  is used)

See the validation checklist below before using it in a performance.

## Build And Run

From this folder on macOS:

```sh
bash scripts/test.sh
bash scripts/run.sh
```

`run.sh` creates `dist/Hand Vision Native.app`, applies a stable local signature,
generates the simple hand icon, and opens the app. The bundle contains
`NSCameraUsageDescription`, so macOS asks for camera access the first time you
press Start. Approving that prompt once is retained across local rebuilds because
the package now has a stable designated requirement instead of a changing
cdhash-only identity. Resetting camera privacy, changing the bundle identifier,
or signing with a different identity will make macOS ask again. Build output and
`dist/` are ignored by Git.

The header displays `CFBundleShortVersionString` and `PoseDtxReleaseDate` from
the packaged `Info.plist`, so a downloaded build can be matched directly to its
GitHub Release.

Individual commands:

```sh
bash scripts/build.sh
bash scripts/package-app.sh
swift run HandVisionNative --self-test
```

The self-test and Swift tests do not open a camera. They check OSC byte order,
string padding, the 63-float landmark shape, zero-valued z coordinates, the
nine-value metadata shape, settings bounds, the 21-joint ordering, capture
watchdog/backoff behavior, sleep intent, and bounded loss prediction.

## Controls

- Camera selection, refresh, start, and stop
- Saver, Eco, Balanced, Smooth, and automatically selected Custom presets
- One or two hands
- 10-60 Hz tracking cadence
- Low, 640 x 480, or 1280 x 720 AVFoundation session presets
- Centered 1-10x tracking-region zoom
- Arbitrary 0-359.99 degree clockwise input rotation
- Editable OSC destination address/hostname and port
- Explicit Save and Reset for settings
- Hide and Quit controls, with a five-second unlock before Quit can be confirmed
- Live hand count, tracking rate, inference time, dropped frames, CPU, RAM, OSC
  destination, and errors. GPU is omitted because macOS has no reliable public
  unprivileged API for per-process GPU use.

Saved settings use `UserDefaults` under the app bundle identifier
`site.posedtx.hand-vision-native`. Changes are applied immediately; Save makes
them the next-launch defaults, while Reset removes the saved values.

Only one app instance is allowed per macOS user. A process-level advisory lock
prevents copied bundles, direct executable launches, or `open -n` from creating
a second camera capture and OSC sender; the lock is released automatically on
quit or crash.

## OSC Contract

Each detected hand is assigned to slot 0 or 1 from left to right. A crossing can
therefore swap slots; this first prototype does not implement identity tracking.
Vision coordinates retain Vision's lower-left origin, as expected by the
TouchDesigner controls. Zoom uses Vision's centered `regionOfInterest`. Vision
reports recognized points relative to that ROI, so emitted coordinates use the
reported x and y directly; they stay normalized within the zoomed region.

- `/hand/0/landmarks`: 63 float32 values, `x y z` for 21 points
- `/hand/0/meta`: 9 float32 values
- `/hand/1/landmarks`: 63 float32 values
- `/hand/1/meta`: 9 float32 values
- `/hands/active`: two int32 values
- `/tracking/status`: `app_running tracking_active hand_count tracking_fps`

Metadata order matches the existing app:

```text
score pinch01 grab01 force01 spread01 palm_x palm_y palm_angle velocity
```

The gesture metadata formulas mirror the browser app's 2D calculations. Every
landmark z value is sent as `0.0`.

The UDP sender automatically reconnects after a failed Network.framework
connection, including when a receiver starts after tracking has already begun.
A missing local UDP listener (`ECONNREFUSED`) is treated as normal best-effort
delivery and does not leave a red UI error; other transport/configuration errors
remain visible. At most 16 sends may be in flight. While the connection is not
ready or that window is full, only the newest complete tracking frame and newest
status packet are retained. This bounds memory without mixing landmarks,
metadata, and `/hands/active` from different frames or bursting an old backlog
into the receiver later.

`/tracking/status` is emitted immediately when the app starts, changes state, or
detects a different hand count, and at a steady 1 Hz thereafter. Hand-count
edges follow `/hands/active`, giving receivers a redundant, immediate
hand-present/absent update. Its dedicated utility queue reads a locked status
snapshot, so camera startup and Vision inference cannot starve the heartbeat.
It continues while tracking is stopped, when no hands are present, and while the
window is hidden. The values are always `app_running` int32, `tracking_active`
int32, `hand_count` int32, and `tracking_fps` float32, in that order. A clean
quit sends `[0, 0, 0, 0.0]` once before closing OSC.

### Joint Ordering

| Index | MediaPipe name | Apple Vision joint |
|---:|---|---|
| 0 | wrist | wrist |
| 1 | thumb_cmc | thumbCMC |
| 2 | thumb_mcp | thumbMP |
| 3 | thumb_ip | thumbIP |
| 4 | thumb_tip | thumbTip |
| 5 | index_mcp | indexMCP |
| 6 | index_pip | indexPIP |
| 7 | index_dip | indexDIP |
| 8 | index_tip | indexTip |
| 9 | middle_mcp | middleMCP |
| 10 | middle_pip | middlePIP |
| 11 | middle_dip | middleDIP |
| 12 | middle_tip | middleTip |
| 13 | ring_mcp | ringMCP |
| 14 | ring_pip | ringPIP |
| 15 | ring_dip | ringDIP |
| 16 | ring_tip | ringTip |
| 17 | pinky_mcp | littleMCP |
| 18 | pinky_pip | littlePIP |
| 19 | pinky_dip | littleDIP |
| 20 | pinky_tip | littleTip |

## Frame And Compute Policy

`AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames` is enabled. Its sample
delegate runs directly on one serial inference queue, and Vision is performed
synchronously on that queue. No second queue receives copied sample buffers, so
inference cannot build a backlog and AVFoundation keeps at most the latest
pending frame. Each rebuilt capture pipeline gets a new video output object, so
a callback queued by a disconnected camera cannot be mistaken for a frame from
the replacement pipeline.

Status and preview publications to AppKit are latest-value coalesced: at most one
main-queue delivery per stream can be pending, and a newer frame replaces a stale
one. Hide calls `orderOut` first and returns from the click event before preview
detachment. The deferred cleanup can therefore wait on AVFoundation without
delaying the window disappearing, while all camera and Vision work stays on the
inference queue.

The visible preview uses AVFoundation's direct preview layer rather than copied
or converted sample buffers. The overlay maps Vision's ROI-relative points
directly into the clipped, rotated, zoomed viewport and uses the actual camera
pixel-buffer aspect ratio. Closing or minimizing the settings window sets the
preview layer's session to `nil` whenever the window is closed, minimized,
hidden, or fully occluded; overlay publication/path construction and the
one-second CPU/RAM sampler stop too. Live label writes are also skipped and the
menu-bar status only changes on actual state transitions. Capture, Vision, and
OSC continue through the menu-bar app without preview/UI rendering work.

Exact 0, 90, 180, and 270 degree rotations use Vision's EXIF-orientation path
and do not create a rotated frame. Other angles use a lazy Core Image rotation
around frame center, expand the image extent so content is not cropped, and let
Vision realize that image synchronously. Arbitrary-angle mode can therefore add
Core Image CPU/GPU work; use a quarter-turn angle for the lowest live load.

Cadence is enforced before Vision inference. The Low resolution preset is
device-dependent; the other choices request AVFoundation's 640 x 480 and
1280 x 720 presets, falling back to Medium if unsupported.
The app never writes `activeVideoMinFrameDuration` or
`activeVideoMaxFrameDuration`. macOS can expose built-in, USB, and virtual
cameras through `AVCaptureDALDevice`, whose frame-duration properties may raise
an Objective-C exception that Swift cannot catch. Instead, `FrameCadence` caps
Vision inference before each request and late camera frames are discarded, so
camera safety does not create an inference backlog.

The preview also leaves `AVCaptureConnection` orientation and mirroring controls
untouched. Some DAL drivers raise the same kind of uncatchable exception while
those connection properties are queried or changed. The app accepts the direct
preview layer's system-managed presentation and draws landmarks in a separate,
lightweight Core Animation overlay. Live verification on the built-in FaceTime
camera showed that the preview and Vision output already share the same
presentation, so no additional horizontal reflection is applied.

An empty Vision result is held for at most two processed frames and 100 ms.
During that short gap, landmarks use constant-velocity prediction capped to
0.12 of normalized frame size and clamped to the valid coordinate range. A real
loss is emitted immediately after either bound, so stale hands cannot persist.

While tracking, the app holds a latency-critical `ProcessInfo` activity that
allows normal idle system sleep but prevents hidden menu-bar tracking from being
App-Napped. The token is released on Stop, camera disconnect, shutdown, and
before sleep. Sleep preserves the user's Start intent, tears capture down, and
rebuilds it after wake. Starting, wake, and interruption recovery are not marked
Tracking until a new sample buffer arrives. A one-second health check rebuilds
a session after three seconds without a sample and exponentially backs repeated
attempts off to a 30-second ceiling; macOS runtime errors trigger the same full
reconstruction path. `/tracking/status` reports `tracking_active = 0` until a
new frame proves the pipeline is live.
If the saved camera is already unavailable when Start, wake, or a settings
rebuild occurs, the app tears down any previous session but preserves the Start
intent and waits for that camera. A transient input/output configuration failure
also enters the watchdog retry path instead of silently stopping tracking.

Apple Vision does not expose a supported control here to force hand-pose
inference onto CPU, GPU, or Neural Engine. macOS manages that placement, so the
app should not be described as CPU-only or GPU-free merely because it is native.

## Browser App Feature Comparison

The useful browser-app behavior retained here is camera selection and automatic
refresh, preview landmarks, Saver/Eco/Balanced/Smooth plus Custom tuning, one or
two hands, arbitrary zoom and rotation, editable OSC destination, saved settings,
live rate/inference/drop/resource status, hide-to-menu-bar behavior, and the
five-second quit safeguard.

Browser-only controls that do not map cleanly to Apple Vision are intentionally
not copied: MediaPipe model complexity, CPU/GPU delegate selection, tracking
pixel width, and MediaPipe processing delay. Fake-hand simulation and a separate
OSC packet repeater also remain browser-only. Vision sends each newly processed
camera result once rather than repeating the latest frame at an independent OSC
rate, which avoids stale duplicate packets and extra scheduler work.

## macOS Handoff Checklist

1. Run `bash scripts/test.sh` and fix any Swift/macOS SDK compile diagnostics.
2. Run `bash scripts/package-app.sh` and verify the bundle with
   `codesign --verify --deep --strict "dist/Hand Vision Native.app"`.
3. Launch the packaged app, grant camera permission, and verify every listed
   camera can start and stop without reopening the app.
4. Inspect OSC packets for exact type tags: 63 `f` values, 9 `f` values, two
   `i` values, and `iiif` for `/tracking/status`.
5. Confirm the preview and landmarks agree for centered zoom and arbitrary
   rotation, and that closing/minimizing the window detaches preview rendering.
6. Confirm zoomed points stay normalized within the selected region. The macOS
   Vision SDK's `VNImagePointForNormalizedPointUsingRegionOfInterest` contract
   documents recognized normalized points as relative to the request ROI.
7. Compare Saver, Eco, Balanced, and Smooth in Activity Monitor beside the
   intended production workload.
8. Test camera unplug/replug and sleep/wake. The app refreshes devices
   automatically on connection changes, waits for the selected camera after a
   disconnect, and resumes capture after camera reconnection, AVFoundation
   interruption or runtime error, or system wake when possible. Confirm
   `/tracking/status` stays live, `tracking_active` remains zero until the first
   resumed sample, and Activity Monitor does not show App Nap while tracking.
9. Hide the window for at least 20 minutes and verify landmark packets continue.
   Compare two-minute median/p95 process CPU, inference rate, dropped frames,
   detection gaps, and fast-sweep success before and after this change on the
   actual production camera; camera-free tests cannot establish those hardware
   measurements.
10. Set `CODE_SIGN_IDENTITY` to a Developer ID identity and notarize before
   distributing the app to another Mac. The default stable local requirement is
   intended for this Mac, not public distribution.

## Source Layout

```text
Package.swift
Info.plist
Sources/HandVisionCore/       OSC, settings, joint mapping, metadata
Sources/HandVisionNative/     AppKit UI, AVFoundation/Vision tracker, UDP
Tests/HandVisionCoreTests/    Camera-free unit tests
scripts/                      Build, test, package, and run helpers
```
