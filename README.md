<div align="center">

# PopNotch

**Turn the MacBook camera notch into something useful.**

Hover the notch and it expands into a panel with what's playing, your system stats, and a per-app volume mixer.<br>
Move the cursor away and it disappears back into the bezel.

<a href="https://github.com/Yuwa709/PopNotch/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Yuwa709/PopNotch?style=for-the-badge&label=version&color=FF9F0A"></a>
<img alt="macOS 14.2 or later" src="https://img.shields.io/badge/macOS-14.2%2B-111111?style=for-the-badge&logo=apple&logoColor=white">
<img alt="Apple Silicon only" src="https://img.shields.io/badge/Apple_Silicon-arm64-111111?style=for-the-badge&logo=apple&logoColor=white">
<br>
<img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white">
<img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-0A84FF?style=for-the-badge&logo=swift&logoColor=white">
<a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/Yuwa709/PopNotch?style=for-the-badge&color=34C759"></a>
<a href="https://github.com/Yuwa709/PopNotch/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/Yuwa709/PopNotch?style=for-the-badge&logo=github&color=FFD60A"></a>

[**Download**](https://github.com/Yuwa709/PopNotch/releases/latest) · [Features](#features) · [Install](#install) · [Build from source](#build-from-source) · [Privacy](#privacy)

</div>

<!-- TODO(user): screenshot of the expanded notch over the bezel goes here.
     docs/screenshot.png — needs a human with eyes on the real display. -->

---

PopNotch is a native Swift and SwiftUI app. It has no web runtime and no Electron, and it lives in the menu bar without a Dock icon. An overlay that costs you battery is worse than no overlay, so nothing samples in the background. Stats stop polling when they're off screen or the display is asleep, and playback updates arrive as notifications from the player instead of by polling it.

## Features

### 🎵 Now Playing

- **Spotify** and **Apple Music**: artwork, title, artist, play/pause/skip, shuffle and repeat, and a scrubbable progress bar. The accent color comes from the album artwork.
- **Any other player**, a browser included, shows through macOS's own now-playing session.
- **Time-synced lyrics** come from the player when it has them, and from [LRCLIB](https://lrclib.net) when it doesn't.
- **Up Next** shows the next track for Apple Music playlists and albums.
- **Audio visualiser** (optional): a live waveform drawn from the music itself.

### 🎚️ Mixer *(optional)*

- Turn **individual apps** up or down, up to twice their normal volume, with a limiter so nothing clips.
- **Route each app to its own output**, for example Spotify to the speakers and a browser to your headphones.
- **Per-app bass boost** of +6, +12 or +18 dB.

### 📊 System stats

- CPU, memory, disk, GPU and battery.
- A battery page that answers *how long*: time until full, time until empty, and what your Mac is drawing right now.

### 📋 Clipboard and File Shelf *(optional)*

- **Clipboard history**, one click from the notch.
- **File Shelf**: drop files on the notch, then drag them out again or share them over AirDrop.

### ⚙️ Everything else

- Launch at login, adjustable hover delay, per-feature on/off switches, and a Permissions pane that shows exactly what's granted.
- Respects **Reduce Motion**.
- Manual-only updates through Sparkle.

Optional features are **off by default**. Anything you leave off doesn't run and uses no CPU or battery.

## Requirements

| | |
|---|---|
| **Mac** | A MacBook with a camera notch: **MacBook Pro (2021 or later)** or **MacBook Air (2022 or later)** |
| **macOS** | **14.2 Sonoma** or later |
| **Chip** | Apple Silicon only. No Intel Mac has a notch, so there is no Intel build |

It runs on any Apple Silicon Mac. A display without a notch gets a small fallback strip, but the notch is the point.

## Install

Download the latest `PopNotch-<version>.dmg` from [**Releases**](https://github.com/Yuwa709/PopNotch/releases/latest).

PopNotch is not notarized, so macOS blocks the first launch until you approve it:

1. Open the DMG and drag **PopNotch** to **Applications**.
2. Double-click PopNotch. macOS blocks it.
3. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the PopNotch notice.
4. Authenticate, then click **Open**. macOS only asks once.

> [!NOTE]
> PopNotch has no Dock icon and no window, so a blocked launch looks like nothing happened. It isn't broken. It's waiting for step 3.

This is only needed on first install. Updates through **Settings → About → Check for Updates** don't repeat it.

<details>
<summary><b>Troubleshooting</b></summary>

- **No Open Anyway button?** It only appears after a launch attempt, and only for a while. Double-click PopNotch again, then reopen Privacy & Security.
- **"PopNotch is damaged" with no Open Anyway button?** On macOS 26 some unnotarized apps get this message instead. For that case only, run:

  ```bash
  xattr -cr /Applications/PopNotch.app
  ```

</details>

## Build from source

```bash
git clone https://github.com/Yuwa709/PopNotch.git
cd PopNotch
./scripts/install.sh
open /Applications/PopNotch.app
```

`install.sh` builds the app, replaces any running copy, and installs it to `/Applications`. Builds you compile yourself are never quarantined, so they skip the Open Anyway step.

## Permissions

| Permission | Asked when | Why |
|---|---|---|
| **Automation** for Spotify and/or Music | The notch first opens with that player running | Reading the current track and controlling playback works over AppleScript. One prompt per player. |
| **System Audio Recording** | You turn on the audio visualiser, or per-app volume for apps other than Spotify and Music | The visualiser reads the audio to draw it, and the mixer adjusts each app's audio stream. Neither records or stores anything. |

Decline either one and the rest of the notch keeps working. The affected feature hides or shows a one-line hint. You can grant the permission later in **System Settings → Privacy & Security**, and PopNotch's **Permissions** pane links straight there.

## Privacy

**No analytics, no telemetry, no accounts. Ever.** The only network requests are the ones a feature needs:

- **Album artwork**, from the URL Spotify itself provides
- **Lyrics lookups** to [LRCLIB](https://lrclib.net), which receive the song title, artist and duration, and nothing about you
- **Update checks**, only when you press the button

The source is public so you can check.

## Known limitations

- **Spotify artwork needs the Automation permission.** Spotify broadcasts track details without it, but artwork is fetched over AppleScript.
- **Other players get fewer controls.** Players reached through macOS's now-playing session have no Up Next and no like button.
- **Lyrics coverage is whatever LRCLIB has.** Instrumentals and obscure tracks may show none. Untimed, plain-text lyrics are skipped because the notch can't scroll them.
- **Not notarized.** See [Install](#install).
- **External displays** get a plain fallback strip, not the full experience.

<details>
<summary><b>Upgrading from a version with Spotify account sign-in</b></summary>

Earlier versions could connect a Spotify account. That feature was removed because Spotify caps it at 25 users. If you connected one, an unused token may still be in your login keychain. Nothing reads it, and this removes it:

```bash
security delete-generic-password -s com.techie.PopNotch -a spotify-refresh-token
```

</details>

## License

[MIT](LICENSE). Third-party components and their licenses are listed in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
