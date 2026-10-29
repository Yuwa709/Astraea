<div align="center">

<img src="docs/images/logo.png" alt="Astraea app icon: a gold star on deep purple" width="128" height="128">

# Astraea

**Turn the MacBook camera notch into something useful.**

Hover the notch and it expands into a panel with what's playing, your system stats, and a per-app volume mixer.<br>
Move the cursor away and it disappears back into the bezel.

<a href="https://github.com/Yuwa709/Astraea/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Yuwa709/Astraea?style=for-the-badge&label=version&color=FF9F0A"></a>
<img alt="macOS 14.2 or later" src="https://img.shields.io/badge/macOS-14.2%2B-111111?style=for-the-badge&logo=apple&logoColor=white">
<img alt="Apple Silicon only" src="https://img.shields.io/badge/Apple_Silicon-arm64-111111?style=for-the-badge&logo=apple&logoColor=white">
<br>
<img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white">
<img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-0A84FF?style=for-the-badge&logo=swift&logoColor=white">
<a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/Yuwa709/Astraea?style=for-the-badge&color=34C759"></a>
<a href="https://github.com/Yuwa709/Astraea/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/Yuwa709/Astraea?style=for-the-badge&logo=github&color=FFD60A"></a>

[**Download**](https://github.com/Yuwa709/Astraea/releases/latest) · [Features](#features) · [Install](#install) · [Build from source](#build-from-source) · [Privacy](#privacy) · [Release history](#release-history)

</div>

<!-- TODO(user): screenshot of the expanded notch over the bezel goes here.
     docs/screenshot.png — needs a human with eyes on the real display. -->

---

Astraea is a native Swift and SwiftUI app. It has no web runtime and no Electron, and it lives in the menu bar without a Dock icon. An overlay that costs you battery is worse than no overlay, so nothing samples in the background. Stats stop polling when they're off screen or the display is asleep, and playback updates arrive as notifications from the player instead of by polling it.

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
- **Battery in the notch** when nothing is playing: a small battery beside the camera, green on the charger, with time until full or empty on the other side.

### 📋 Clipboard and File Shelf *(optional)*

- **Clipboard history**, one click from the notch.
- **File Shelf**: drop files on the notch, then drag them out again or share them over AirDrop.

### 🪟 Window Layouts *(optional)*

- **Drag any window into the notch** and a picker of layouts opens. Keep holding, move onto a zone (left half, top-right quarter, a third, full screen) and let go: the window snaps there, on the screen it came from.
- **Draw your own layouts** on a grid of up to 6 columns and 4 rows, and hide the built-in ones you don't use. Both live under **Window Layouts** in Features.
- Apps with a minimum size, like Spotify, stay against the screen edges of their zone instead of hanging off the screen.

### 🔓 Face Unlock *(optional)*

- Wake your Mac at the lock screen and look at the camera. When Astraea recognises you, it types your password. Nothing leaves your Mac.
- Enrol a few angles of your face in Settings. Your face is stored as encrypted numbers, never as pictures, with the key in your login keychain. Touch ID or your password is needed before any of it can be changed.
- A liveness check refuses a scan that shows screen glare or the edge of a phone, and only the built-in camera is used. A carefully held photo can still pass: this is a convenience, not Apple's Face ID, and your password remains the real lock.

### ⚙️ Everything else

- Launch at login, adjustable hover delay, per-feature on/off switches, and an option to reopen the notch on the page you last left it on.
- Respects **Reduce Motion**.
- Updates through Sparkle. Astraea checks once a day and, when a new version is out, says so in the notch: a badge beside the camera, and an Install button when you hover. Turn off **Update Notices** in Features to check manually from About instead.

Optional features are **off by default**. Anything you leave off doesn't run and uses no CPU or battery.

## Requirements

| | |
|---|---|
| **Mac** | A MacBook with a camera notch: **MacBook Pro (2021 or later)** or **MacBook Air (2022 or later)** |
| **macOS** | **14.2 Sonoma** or later |
| **Chip** | Apple Silicon only. No Intel Mac has a notch, so there is no Intel build |

It runs on any Apple Silicon Mac. A display without a notch gets a small fallback strip, but the notch is the point.

## Install

Download the latest `Astraea-<version>.dmg` from [**Releases**](https://github.com/Yuwa709/Astraea/releases/latest).

1. Open the DMG and drag **Astraea** to **Applications**.
2. Double-click Astraea. macOS asks once to confirm you want to open an app downloaded from the internet. Click **Open**.

Astraea is signed with a Developer ID and notarized by Apple, so Gatekeeper lets it run without a trip to System Settings.

> [!NOTE]
> Astraea has no Dock icon and no window. It lives in the menu bar and around the notch, so a successful launch can look like nothing happened. Hover the notch.

<details>
<summary><b>Upgrading from 1.3.2 or earlier</b></summary>

Those releases were not notarized and used a different signature. The first notarized update looks like a new app to macOS, so it asks once more for **Accessibility** and for Face Unlock's keychain access. After that, updates keep your permissions.

</details>

## Build from source

```bash
git clone https://github.com/Yuwa709/Astraea.git
cd Astraea
./scripts/install.sh
open /Applications/Astraea.app
```

`install.sh` builds the app, replaces any running copy, and installs it to `/Applications`. Builds you compile yourself are never quarantined, so they skip the Open Anyway step.

## Permissions

| Permission | Asked when | Why |
|---|---|---|
| **Automation** for Spotify and/or Music | The notch first opens with that player running | Reading the current track and controlling playback works over AppleScript. One prompt per player. |
| **System Audio Recording** | You turn on the audio visualiser, or per-app volume for apps other than Spotify and Music | The visualiser reads the audio to draw it, and the mixer adjusts each app's audio stream. Neither records or stores anything. |
| **Camera** | You add a face in Face Unlock | Enrolling and recognising your face. Frames are processed on your Mac and never saved. |
| **Accessibility** | You turn on **Unlock the Mac at the lock screen**, or **Window Layouts** | Typing your password into the lock screen's password field, and moving and resizing the window you drop on a layout. |

Decline any of them and the rest of the notch keeps working. The affected feature hides or shows a one-line hint. You can grant the permission later in **System Settings → Privacy & Security**, and Astraea's settings link straight there (Spotify and Music access is under **Music → Player Access**).

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
| [**1.5.0**](https://github.com/Yuwa709/Astraea/releases/tag/v1.5.0) <br><sub>Latest</sub> | Oct 29, 2026 | **Window Layouts.** Drag a window into the notch, move onto a zone of a layout, and let go: the window snaps to that half, quarter or third of the screen it came from. Draw your own layouts on a grid, and hide the built-ins you don't use. Off by default; turn it on in **Features**. |
| [**1.4.3**](https://github.com/Yuwa709/Astraea/releases/tag/v1.4.3) | Oct 26, 2026 | **Pick up where you left off.** A new **Reopen last page** option in General opens the notch on the page you last had open, such as Clipboard, instead of the home screen. Settings is reorganized into five pages with coloured icons: Modules is now **Features**, with a line on what each one does, and Spotify and Music access moved from Permissions into **Music**. |
| [**1.4.2**](https://github.com/Yuwa709/Astraea/releases/tag/v1.4.2) | Oct 21, 2026 | **Battery in the notch.** When nothing is playing, the notch shows a small battery on the right (green on the charger) and the time until full or empty on the left. It switches the moment you plug in or unplug, and updates only when the battery reports a change. Turn it off with **System Stats** in Modules. Face Unlock now also scans when the screen locks, not only when it wakes. |
| [**1.4.1**](https://github.com/Yuwa709/Astraea/releases/tag/v1.4.1) | Oct 21, 2026 | **Face Unlock works again**: 1.4.0 refused its own face model after an Xcode update changed the model's build stamp. A new night-sky install window, and the keychain item is now called "Astraea Face Unlock" for new setups. |
| **1.4.0** | Oct 21, 2026 | **PopNotch is now Astraea, and it's notarized.** Signed with an Apple Developer ID and notarized, so a first install opens without a trip to Privacy & Security. Settings carry over from PopNotch. Re-grant Accessibility and Face Unlock's keychain access once after updating; that identity is permanent. |
| **1.3.2** | Oct 15, 2026 | **Permissions that survive updates.** Astraea is now signed with a stable identity, so Accessibility and Face Unlock's keychain access stay granted across updates (re-grant them once after installing 1.3.2). A **Grant Access** button for the camera in Face Unlock's settings. |
| **1.3.1** | Oct 15, 2026 | **Update notices in the notch.** Astraea now checks for updates once a day and shows a new version in the notch: a badge beside the camera and an Install button when you hover. Turn off **Update Notices** in Modules to check manually instead. |
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
