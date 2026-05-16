# tomatt

`tomatt` is a macOS menu bar Pomodoro timer.

## Features

- Menu bar timer for work, short rest, and long rest sessions.
- Configurable durations and keyboard shortcuts.
- Optional notifications and sound cues.
- URL automation through `tomatt://` commands:
  - `open tomatt://startStop`
  - `open tomatt://pauseResume`
  - `open tomatt://skip`
- JSON state transition logs at:
  `~/Library/Containers/app.tomatt.tomatt/Data/Library/Caches/tomatt.log`

## Builds

Signed and notarized macOS builds are produced only by GitHub Actions on push/tag. Do not build, sign, or notarize locally.

The CI artifact installs as:

```text
/Applications/tomatt.app
```

## Licenses

- Timer sounds are licensed from buddhabeats.
