# Baby Monitor for macOS

A native macOS menu bar app for **Philips Avent connected baby monitors** (SCD973, SCD923 and
other cameras on the *Baby Monitor+* app). Watch your camera in a window or in system
Picture in Picture, and see at a glance, from the menu bar or the Dock, when there is sound
or movement in the room.

It is built on [aventproxy](https://github.com/thekoma/aventproxy), which reverse-engineered
the cameras' cloud and WebRTC protocol. This app embeds its bridge, so there is nothing else
to install or run.

> Not affiliated with Philips, Philips Avent or Tuya. Use at your own risk.
> The interface is in French.

## Features

- Sign in with your *Baby Monitor+* account (email, password and the emailed code).
- Live video and sound, in a window that can stay on top of every Space.
- System Picture in Picture, which floats above full-screen apps.
- Room sound level, as three bars like the official app.
- Sound and motion detection, shown on the video, on the menu bar icon and on the Dock icon
  for a minute after each event.
- A thumbnail of each camera in the menu bar panel, without keeping a stream open.
- Night light (on/off, brightness, auto-off timer) and the monitor's 15 lullabies and soothing
  sounds (play/pause, track, volume, repeat mode, stop timer), from the camera window or straight
  from the menu bar panel. The room temperature shows on the video and on the thumbnail.
- Talk through the camera: hold the mic button or the space bar. The bridge only opens the
  return audio channel while talk mode is on (it ends after 3 minutes of silence), because the
  monitor pauses a playing lullaby while that channel is open.
- Optional Dock icon, menu bar icon and launch at login.

## How it works

```
Baby Monitor+ cloud (Tuya) ──login, discovery──▶ AventCore (Go, embedded)
                                                     │
camera ──WebRTC──▶ aventproxy bridge ──RTSP on 127.0.0.1──▶ RTSPClient (Swift)
                                                                │
                              H.264 ─▶ VideoToolbox ─▶ display layer, motion, thumbnails
                              G.711 ─▶ AVAudioEngine, sound level
```

| Path | What it holds |
| --- | --- |
| `Core/` | `AventCore`, a Go static library: login and camera discovery against the Tuya mobile API, and aventproxy's WebRTC→RTSP bridge. Swift calls it through one JSON function (`AventCall`). |
| `Sources/Core/` | The Swift side of that boundary, the models, and the Keychain session store. |
| `Sources/Stream/` | A minimal RTSP client, RTP/H.264 depacketisation, decoding, audio, motion and sound detection. |
| `Sources/App/`, `Sources/UI/` | The app model and the SwiftUI/AppKit interface. |
| `Vendor/aventproxy/` | aventproxy, as a git submodule. |
| `Patches/aventproxy/` | Fixes to aventproxy's bridge not yet upstream. `Scripts/build-core.sh` applies them to a copy in `Build/aventproxy-bridge`, which `Core/go.mod` builds against, so the submodule stays untouched. |

## Building

Requirements: macOS 15 on Apple silicon, Xcode 16 or later, Go, Python 3 and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install go xcodegen
git clone --recurse-submodules <this repository>
cd AventMonitor
make build      # Debug build; or `make install` to build Release into ~/Applications
make test       # Go and Swift unit tests
```

The Xcode project is generated from `project.yml` (`make project`, then open
`AventMonitor.xcodeproj`). A build phase compiles the Go core with `Scripts/build-core.sh`; it
also reads the app's API keys from aventproxy's `const.py` into `Core/keys_gen.go`.

### Code signing

Builds are signed ad hoc by default. That works, but macOS treats each rebuild as a new app and
asks again for Keychain access. To sign with your own certificate:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# then set CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM in it
```

## Privacy and security

- Your password is only used to sign in and is never stored. The session token is kept in
  your login Keychain; signing out deletes it, along with the cached thumbnails.
- Video goes from the camera to the embedded bridge, then to the app over an RTSP server
  bound to `127.0.0.1`. That server has no authentication, so other processes on your Mac
  could read the stream while the app runs. Nothing listens on the network.
- The microphone is never opened.
- The bridge logs to `~/Library/Application Support/AventMonitor/bridge.log`.

## Credits and license

MIT, see [LICENSE](LICENSE). Built on [aventproxy](https://github.com/thekoma/aventproxy) (MIT)
by thekoma.
