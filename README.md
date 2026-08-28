# OwlCap

A screen recorder for macOS that does what QuickTime Player used to do — and records
your Mac's own audio without any extra drivers.

QuickTime can only record a microphone. If you want the sound your Mac is *playing* —
a video, a game, a call — QuickTime has never captured it, and the usual workaround is
installing a virtual audio driver like BlackHole or Soundflower and rerouting your
output through it. OwlCap skips all of that: macOS has had a proper system-audio tap in
ScreenCaptureKit since Ventura, and OwlCap uses it directly.

## What it does

**Everything QuickTime's screen recording had**

- Record the entire screen, on whichever display you choose
- Record a selected portion — drag to pick an area
- Record a single window, or every window belonging to one app
- Show or hide the pointer
- Highlight mouse clicks
- A 3 / 5 / 10 second countdown before it starts
- Audio-only recording, saved as `.m4a`
- Stop from the menu bar, or with ⌘⌃⎋ from anywhere

**Plus the parts it was missing**

- **Computer audio.** Captured straight from macOS — no BlackHole, no Soundflower, no
  changing your output device.
- **Both at once.** System audio and your microphone are mixed into one track, so
  narration over a video just works.
- **Live meters.** You can see the sound going in before and while you record, so you
  never end up with a silent file you didn't notice until afterwards.
- **Pause and resume** mid-recording.
- **Real quality controls** — 24/30/60 fps, HEVC or H.264, three quality levels,
  `.mov` or `.mp4`, and full Retina resolution on or off.
- Choose where recordings are saved.

## Install

Download the latest `OwlCap.zip` from
[Releases](https://github.com/Unknownce0/owlcap/releases), unzip it, and drag
**OwlCap.app** into your Applications folder.

The app is signed ad-hoc rather than with a paid Apple Developer certificate, so the
first launch needs one extra step: **right-click OwlCap → Open**, then confirm. After
that it opens normally.

### Build it yourself

Needs the Swift toolchain — either Xcode or the Command Line Tools
(`xcode-select --install`).

```bash
git clone https://github.com/Unknownce0/owlcap.git
cd owlcap
./build.sh --install
```

`--install` copies the finished app to `/Applications`. Leave it off to just get
`build/OwlCap.app`. Add `--zip` for a distributable archive.

## Permissions

macOS gates both of the things this app needs. You only grant them once.

1. **Screen & System Audio Recording** — required, and it covers computer audio too.
   System Settings › Privacy & Security › Screen & System Audio Recording → switch
   **OwlCap** on. OwlCap will ask the first time you record.
2. **Microphone** — only if you turn the microphone on.

### If it keeps asking even though the switch is already on

That is the ad-hoc signature, not you. macOS ties the Screen Recording grant to the
app's exact signature, and an ad-hoc signature changes with every single build — so
after a rebuild the switch in System Settings still looks on while the grant underneath
no longer matches the app.

Two things fix it:

- **Quit and reopen OwlCap.** A running app keeps the answer it got at launch, so it
  will keep asking until it is restarted. `./build.sh --install` now relaunches it for
  you.
- If it still asks, clear the stale grant and approve once more:

  ```bash
  ./build.sh --install --reset-permission
  ```

Downloaded releases are not affected — the permission sticks until you replace the app.

## Checking your audio actually works

Because that is the whole reason this exists, there is a one-command check:

```bash
/Applications/OwlCap.app/Contents/MacOS/OwlCap --selftest 5
```

It records the main display for five seconds with computer audio on, then decodes the
finished file and prints what really ended up in it — duration, video size, track
count, and the loudest sample it can find. Play something first, or it will honestly
report silence.

| flag | what it checks |
| --- | --- |
| `--mic` | microphone capture, mixed in with computer audio |
| `--audio-only` | audio-only `.m4a` recording |
| `--region x,y,w,h` | area capture, in points from the display's top-left |

## Requirements

macOS 14 (Sonoma) or later. Apple silicon and Intel.

## How it works

- `Recorder.swift` sets up the ScreenCaptureKit stream and the AVAssetWriter.
- `CaptureWriter.swift` owns the writer. Every sample — video, system audio, mic —
  is handled on one serial queue, which is also what makes pause/resume safe: it holds
  a single running offset and subtracts it from every timestamp.
- `AudioPipeline.swift` normalises whatever the two audio sources hand over
  (any sample rate, any channel count) to 48 kHz stereo float and mixes them. System
  audio drives the clock; the microphone is buffered and summed into each chunk, with
  silence padding on underrun rather than a glitch.
- `Overlays.swift` has the area picker, the countdown, and the click highlighter. The
  highlighter is a transparent click-through window, so the capture picks it up the
  same way QuickTime's did.

## License

MIT — see [LICENSE](LICENSE).
