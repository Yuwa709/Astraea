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

[**Download**](https://github.com/Yuwa709/PopNotch/releases/latest) · [Features](#features) · [Install](#install) · [Build from source](#build-from-source) · [Privacy](#privacy) · [Release history](#release-history)

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

### 🔓 Face Unlock *(optional)*

- Wake your Mac at the lock screen and look at the camera. When PopNotch recognises you, it types your password. Nothing leaves your Mac.
- Enrol a few angles of your face in Settings. Your face is stored as encrypted numbers, never as pictures, with the key in your login keychain. Touch ID or your password is needed before any of it can be changed.
- A liveness check refuses a scan that shows screen glare or the edge of a phone, and only the built-in camera is used. A carefully held photo can still pass: this is a convenience, not Apple's Face ID, and your password remains the real lock.

### ⚙️ Everything else

- Launch at login, adjustable hover delay, per-feature on/off switches, and a Permissions pane that shows exactly what's granted.
- Respects **Reduce Motion**.
- Updates through Sparkle. PopNotch checks once a day and, when a new version is out, says so in the notch: a badge beside the camera, and an Install button when you hover. Turn off **Update Notices** in Modules to check manually from About instead.

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
| **Camera** | You add a face in Face Unlock | Enrolling and recognising your face. Frames are processed on your Mac and never saved. |
| **Accessibility** | You turn on **Unlock the Mac at the lock screen** | Typing your password into the lock screen's password field. |

Decline any of them and the rest of the notch keeps working. The affected feature hides or shows a one-line hint. You can grant the permission later in **System Settings → Privacy & Security**, and PopNotch's **Permissions** pane links straight there.

## Privacy

**No analytics, no telemetry, no accounts. Ever.** The only network requests are the ones a feature needs:

- **Album artwork**, from the URL Spotify itself provides
- **Lyrics lookups** to [LRCLIB](https://lrclib.net), which receive the song title, artist and duration, and nothing about you
- **Update checks**, only when you press the button

Face Unlock works entirely on your Mac. Enrolled faces are stored as encrypted embeddings in your Library folder, the camera runs only while you enrol or at the lock screen, and no frame is ever written to disk or sent anywhere.

The source is public so you can check.

## Known limitations

- **Spotify artwork needs the Automation permission.** Spotify broadcasts track details without it, but artwork is fetched over AppleScript.
- **Other players get fewer controls.** Players reached through macOS's now-playing session have no Up Next and no like button.
- **Lyrics coverage is whatever LRCLIB has.** Instrumentals and obscure tracks may show none. Untimed, plain-text lyrics are skipped because the notch can't scroll them.
- **Not notarized.** See [Install](#install).
- **Face Unlock is not Face ID.** It matches a flat camera image; the liveness check stops screens and phone edges, not every photo. It needs the built-in camera, so it is off with the lid closed, and it does nothing at the FileVault or login screen.
- **External displays** get a plain fallback strip, not the full experience.

<details>
<summary><b>Upgrading from a version with Spotify account sign-in</b></summary>

Earlier versions could connect a Spotify account. That feature was removed because Spotify caps it at 25 users. If you connected one, an unused token may still be in your login keychain. Nothing reads it, and this removes it:

```bash
security delete-generic-password -s com.techie.PopNotch -a spotify-refresh-token
```

</details>

## Release history

| Version | Released | Highlights |
|:---:|:---:|---|
| [**1.3.2**](https://github.com/Yuwa709/PopNotch/releases/tag/v1.3.2) <br><sub>Latest</sub> | Oct 15, 2026 | **Permissions that survive updates.** PopNotch is now signed with a stable identity, so Accessibility and Face Unlock's keychain access stay granted across updates (re-grant them once after installing 1.3.2). A **Grant Access** button for the camera in Face Unlock's settings. |
| **1.3.1** | Oct 15, 2026 | **Update notices in the notch.** PopNotch now checks for updates once a day and shows a new version in the notch: a badge beside the camera and an Install button when you hover. Turn off **Update Notices** in Modules to check manually instead. |
| **1.3.0** | Oct 15, 2026 | **Face Unlock**: unlock your Mac at the lock screen with your face, using the built-in camera. Face data is encrypted and never leaves your Mac. Off by default. |
| **1.2.3** | Oct 14, 2026 | A reliability release from a full review. The overlay stays on the notch when an external display is the main display, and the mixer holds an app's volume through device and sample-rate changes. Clipboard memory is capped, and **Launch at Login** shows when macOS needs your approval. |
| **1.2.2** | Oct 10, 2026 | Mixer sliders can turn apps **up to 2×**, with a limiter so nothing clips. The new battery page shows **time until full or empty** and live power draw. Battery readings work on macOS 27. |
| **1.2.1** | Sep 30, 2026 | **Per-app bass boost** at +6, +12 or +18 dB. **Up Next** for Apple Music playlists and albums. |
| **1.2.0** | Sep 28, 2026 | **Per-app output routing**, to send each app to its own speakers or headphones. Spotify account sign-in removed, which ends the keychain prompts. New Open Anyway install flow. |
| **1.1.0** | Sep 20, 2026 | **Per-app volume mixer**, to adjust individual apps from the notch. |
| **1.0.9** | Sep 16, 2026 | Redesigned expanded player: the scrub bar is a **live audio waveform**, the artwork is larger, and lyrics show one line at a time. |
| **1.0.8** | Sep 16, 2026 | Lower CPU use while the notch is open. The waveform respects **Reduce Motion**. |
| **1.0.7** | Sep 15, 2026 | Fixed background timers that drained the battery after the notch closed. Idle CPU with music playing is down about 40%. |
| **1.0.6** | Sep 8, 2026 | **Shuffle and repeat** for Spotify. The panel stays in sync with changes made in the player. Smoother corners on collapse. |
| **1.0.5** | Sep 2, 2026 | Fixed the stats page leaving timers running after it closed. |
| **1.0.4** | Sep 2, 2026 | **Browsers and YouTube Music** in Now Playing, with nothing extra to install. Spotify and Apple Music keep priority. |
| **1.0.3** | Sep 1, 2026 | Browser playback paused while it was reworked; it returned in 1.0.4. Internal files no longer ship in the app bundle. |
| **1.0.2** | Sep 1, 2026 | A dedicated **system stats and battery page**. Browser players in Now Playing. Buttons no longer hide behind the camera housing. |
| **1.0.1** | Aug 31, 2026 | 🎉 **First public release.** |

## License

[MIT](LICENSE). Third-party components and their licenses are listed in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
