# Moveo Tracker

Apple Vision hand, body, and face tracking to OSC for macOS.

## Use

1. [Download the latest release](https://github.com/jpjullin/moveo-tracker/releases/latest).
2. In Finder, right-click (or Control-click) **Moveo Tracker.app**, choose
   **Open**, then click **Open** again. The release is not signed and notarized
   with an Apple Developer certificate, so macOS requires this on first launch.
3. Choose a camera and model.
4. Press **Start Tracking**.

The OSC destination and addresses are always visible below the camera.
Landmark coordinates and face bounds are normalized to the visible zoom region
with a lower-left origin. Rotation never adds automatic zoom, so rotated frames
may show black corners.

## Build

```sh
bash scripts/package-app.sh
```
