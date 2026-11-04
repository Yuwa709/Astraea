import Foundation

/// A browser that can host a YouTube Music tab Astraea reads directly.
///
/// Chrome and Safari only: both expose tabs and in-page JavaScript through
/// their scripting dictionaries, with nothing to install. Firefox has no
/// tab or JavaScript terms at all, so a YouTube Music tab there stays with
/// the system now-playing source like any other browser media.
enum YouTubeMusicBrowser: String, CaseIterable {
    case chrome
    case safari

    var bundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        }
    }

    /// The name AppleScript's `tell application` resolves.
    var scriptingName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .safari: "Safari"
        }
    }

    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .safari: "Safari"
        }
    }

    /// Where the one switch lives. Shown in the notch hint and in Settings,
    /// so the wording exists once.
    var enableJavaScriptSteps: String {
        switch self {
        case .chrome:
            "In Chrome's menu bar: View › Developer › Allow JavaScript from Apple Events."
        case .safari:
            "Safari › Settings › Advanced › Show features for web developers, then Settings › Developer › Allow JavaScript from Apple Events."
        }
    }

    /// The error number each browser's JavaScript command returns while the
    /// switch is off, read from the live apps on 2026-11-04 (Chrome 12,
    /// Safari 8). The message is checked too, because these small numbers
    /// are not reserved for this one failure.
    var javaScriptOffErrorNumber: Int {
        switch self {
        case .chrome: 12
        case .safari: 8
        }
    }

    static func from(bundleID: String?) -> YouTubeMusicBrowser? {
        allCases.first { $0.bundleID == bundleID }
    }
}

/// One YouTube Music tab, addressed the way its browser allows.
///
/// Chrome gives tabs a stable `id`. Safari does not, so a Safari tab is its
/// index within a window, which shifts when an earlier tab closes. That is
/// safe because every read checks the page's host first and reports the tab
/// lost on a mismatch, which sends the adapter back to a fresh scan.
struct YouTubeMusicTab: Equatable {
    let browser: YouTubeMusicBrowser
    let windowID: Int
    /// Chrome: the tab's `id`. Safari: its 1-based index in the window.
    let tabRef: Int

    var specifier: String {
        switch browser {
        case .chrome: "tab id \(tabRef) of window id \(windowID)"
        case .safari: "tab \(tabRef) of window id \(windowID)"
        }
    }
}

/// What one read of the page found.
struct YouTubeMusicPageState: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    /// Largest artwork the page's media session lists.
    var artworkSource: String?
    /// The page has finished copying that artwork into memory, so a second
    /// read can fetch its bytes.
    var artworkReady: Bool
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var isPlaying: Bool
    /// The `v` query parameter: the track, stable across pause and seek.
    var videoID: String?
}

/// The outcome of running one script against a tab.
enum YouTubeMusicReply: Equatable {
    /// The script returned this text.
    case value(String)
    /// The browser refuses JavaScript from Apple Events.
    case javaScriptOff
    /// Automation for this browser was declined.
    case denied
    /// The browser did not answer within the runner's timeout. Says nothing
    /// about the tab.
    case transient
    /// The tab or window no longer exists.
    case lost
}

/// Script sources and parsing, pure so they can be tested without a browser.
enum YouTubeMusicScripts {

    static let host = "music.youtube.com"
    static let urlPrefix = "https://music.youtube.com/"

    /// Marks an error the AppleScript caught and handed back as text, so a
    /// refused JavaScript call can be told apart from a lost tab without
    /// changing `AppleScriptRunner`.
    static let errorMarker = "ASTRAEA-ERR|"

    // MARK: - Finding tabs

    /// Lists every YouTube Music tab in one browser, one per line:
    /// `windowID<TAB>tabRef<TAB>url`.
    ///
    /// Chrome answers in three bulk reads, whatever the number of tabs.
    /// Safari's `every window` includes windows with no tabs (Settings), so
    /// it reads window by window, each inside its own `try`.
    static func scanSource(for browser: YouTubeMusicBrowser) -> String {
        switch browser {
        case .chrome:
            return """
                tell application "Google Chrome"
                    set out to ""
                    set sep to character id 9
                    try
                        set wids to id of every window
                        set tids to id of every tab of every window
                        set urls to URL of every tab of every window
                    on error
                        return ""
                    end try
                    if (count of wids) is not (count of urls) then return ""
                    repeat with i from 1 to count of wids
                        set ws to item i of urls
                        set ts to item i of tids
                        repeat with j from 1 to count of ws
                            try
                                set u to item j of ws as text
                                if u starts with "\(urlPrefix)" then set out to out & (item i of wids as text) & sep & (item j of ts as text) & sep & u & linefeed
                            end try
                        end repeat
                    end repeat
                    return out
                end tell
                """
        case .safari:
            return """
                tell application "Safari"
                    set out to ""
                    set sep to character id 9
                    repeat with w in (every window)
                        try
                            set wid to id of w
                            set urls to URL of every tab of w
                            repeat with j from 1 to count of urls
                                try
                                    set u to item j of urls as text
                                    if u starts with "\(urlPrefix)" then set out to out & (wid as text) & sep & (j as text) & sep & u & linefeed
                                end try
                            end repeat
                        end try
                    end repeat
                    return out
                end tell
                """
        }
    }

    static func parseScan(_ output: String, browser: YouTubeMusicBrowser) -> [YouTubeMusicTab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let window = Int(fields[0]), let tab = Int(fields[1]),
                  fields[2].hasPrefix(urlPrefix)
            else { return nil }
            return YouTubeMusicTab(browser: browser, windowID: window, tabRef: tab)
        }
    }

    // MARK: - Running JavaScript in a tab

    /// Wraps page JavaScript in the browser's command for one tab, catching
    /// every error inside the script and returning it as marked text.
    static func runSource(javaScript: String, in tab: YouTubeMusicTab) -> String {
        let literal = appleScriptLiteral(javaScript)
        let command: String = switch tab.browser {
        case .chrome: "execute (\(tab.specifier)) javascript \(literal)"
        case .safari: "do JavaScript \(literal) in (\(tab.specifier))"
        }
        return """
            tell application "\(tab.browser.scriptingName)"
                try
                    return \(command)
                on error errMsg number errNum
                    return "\(errorMarker)" & errNum & "|" & errMsg
                end try
            end tell
            """
    }

    static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Classifies what a run returned. `nil` output is a script that returned
    /// nothing, which only a page that is not ours does.
    static func classify(_ output: String?, browser: YouTubeMusicBrowser) -> YouTubeMusicReply {
        guard let output else { return .lost }
        guard output.hasPrefix(errorMarker) else { return .value(output) }
        let rest = output.dropFirst(errorMarker.count)
        let parts = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let number = parts.first.flatMap { Int($0) } ?? 0
        let message = parts.count > 1 ? String(parts[1]) : ""
        if number == -1743 { return .denied }
        if number == -1712 { return .transient }
        let mentionsSwitch = message.localizedCaseInsensitiveContains("JavaScript")
            && message.localizedCaseInsensitiveContains("Apple Events")
        if mentionsSwitch || number == browser.javaScriptOffErrorNumber { return .javaScriptOff }
        return .lost
    }

    // MARK: - Page scripts

    /// Reads the player in one call: the media session's metadata, the
    /// `<video>` element's clock, and whether the artwork has been copied.
    ///
    /// Metadata comes from `navigator.mediaSession`, which YouTube Music
    /// fills for the system's own media controls. That is the page's own
    /// statement of what is playing, not a guess from the tab title.
    ///
    /// Artwork: the page fetches its own artwork URL, almost always from its
    /// cache because the image is already on screen, and keeps the bytes in a
    /// page variable for `artworkSource` to read. Astraea itself makes no
    /// network call (hard rule 6).
    ///
    /// Playing means the element is unpaused *and* has data. A background
    /// tab Chrome has never shown reports `paused == false` with
    /// `readyState == 0` and no sound (measured 2026-11-04); that is not
    /// playing.
    static let stateJavaScript = """
        (function(){
        if(location.hostname!=='\(host)')return JSON.stringify({ok:false});
        var v=document.querySelector('video.html5-main-video')||document.querySelector('video');
        var m=navigator.mediaSession?navigator.mediaSession.metadata:null;
        var art=null,best=-1;
        if(m&&m.artwork){for(var i=0;i<m.artwork.length;i++){var a=m.artwork[i];var w=parseInt(String(a.sizes||'0').split('x')[0],10)||0;if(w>=best){best=w;art=a.src;}}}
        var c=window.__astraeaArt;
        if(art&&(!c||c.src!==art)){window.__astraeaArt={src:art,data:null};
        fetch(art).then(function(r){return r.blob();}).then(function(b){return new Promise(function(res){var f=new FileReader();f.onload=function(){res(f.result);};f.readAsDataURL(b);});}).then(function(d){if(window.__astraeaArt&&window.__astraeaArt.src===art){window.__astraeaArt.data=d;}}).catch(function(){});}
        c=window.__astraeaArt;
        var vid=null;try{vid=new URLSearchParams(location.search).get('v');}catch(e){}
        return JSON.stringify({ok:true,title:m?m.title:null,artist:m?m.artist:null,album:m?m.album:null,
        art:art,artReady:!!(c&&art&&c.src===art&&c.data),
        duration:(v&&isFinite(v.duration))?v.duration:null,elapsed:v?v.currentTime:null,
        playing:!!(v&&!v.paused&&!v.ended&&v.readyState>0),id:vid});
        })()
        """

    /// Returns the copied artwork as a data URL, or an empty string.
    static let artworkJavaScript = """
        (function(){var c=window.__astraeaArt;return (c&&c.data)?c.data:'';})()
        """

    /// The player's own transport buttons, current layout first, then the
    /// older player bar. Clicking the button rather than poking the
    /// `<video>` keeps YouTube Music's queue, UI and its own state in step.
    private static let playPauseButton =
        ".ytmusicPlayerControlsPlayPauseButton button, ytmusic-player-bar #play-pause-button"
    private static let nextButton =
        ".ytmusicPlayerControlsNextButton button, ytmusic-player-bar .next-button"
    private static let previousButton =
        ".ytmusicPlayerControlsPreviousButton button, ytmusic-player-bar .previous-button"

    /// Page JavaScript for one transport command. Returns 'ok' or 'missing'.
    ///
    /// Play and pause check the element first, so a repeated press cannot
    /// flip the state back. A missing play button falls back to the
    /// `<video>` element itself, which always exists while a track is loaded.
    static func commandJavaScript(_ command: MediaCommand) -> String {
        let video = "var v=document.querySelector('video.html5-main-video')||document.querySelector('video');"
        let toggle = "var b=document.querySelector('\(playPauseButton)');if(b){b.click();return 'ok';}"
            + "if(!v)return 'missing';if(v.paused){v.play();}else{v.pause();}return 'ok';"
        let body: String = switch command {
        case .togglePlayPause: video + toggle
        case .play: video + "if(v&&!v.paused)return 'ok';" + toggle
        case .pause: video + "if(v&&v.paused)return 'ok';" + toggle
        case .nextTrack: "var b=document.querySelector('\(nextButton)');if(!b)return 'missing';b.click();return 'ok';"
        case .previousTrack: "var b=document.querySelector('\(previousButton)');if(!b)return 'missing';b.click();return 'ok';"
        }
        return "(function(){\(body)})()"
    }

    static func seekJavaScript(to seconds: TimeInterval) -> String {
        let value = String(format: "%.3f", max(0, seconds))
        return "(function(){var v=document.querySelector('video.html5-main-video')||document.querySelector('video');"
            + "if(!v)return 'missing';v.currentTime=\(value);return 'ok';})()"
    }

    // MARK: - Parsing

    /// Parses the state JSON. `nil` when the page is not YouTube Music (the
    /// tab navigated away, or a Safari index now points elsewhere).
    static func parseState(_ json: String) -> YouTubeMusicPageState? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              object["ok"] as? Bool == true
        else { return nil }
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: String) -> TimeInterval? {
            guard let value = object[key] as? NSNumber else { return nil }
            let double = value.doubleValue
            return double.isFinite ? double : nil
        }
        return YouTubeMusicPageState(
            title: text("title"),
            artist: text("artist"),
            album: text("album"),
            artworkSource: text("art"),
            artworkReady: object["artReady"] as? Bool ?? false,
            duration: number("duration").flatMap { $0 > 0 ? $0 : nil },
            elapsed: number("elapsed"),
            isPlaying: object["playing"] as? Bool ?? false,
            videoID: text("id"))
    }

    /// Decodes a `data:image/...;base64,` URL.
    static func decodeDataURL(_ text: String) -> Data? {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }

    /// The snapshot the notch shows. `nil` when the page has no track loaded
    /// (the home page before anything plays).
    static func snapshot(from state: YouTubeMusicPageState, browser: YouTubeMusicBrowser,
                         artwork: Data?, capturedAt: Date) -> NowPlaying? {
        var snapshot = NowPlaying()
        snapshot.title = state.title
        snapshot.artist = state.artist
        snapshot.album = state.album
        guard snapshot.title != nil || snapshot.artist != nil else { return nil }
        snapshot.artworkData = artwork
        snapshot.artworkIdentifier = state.videoID.map { "youtube-music:\($0)" }
        snapshot.duration = state.duration
        snapshot.elapsed = state.elapsed
        snapshot.isPlaying = state.isPlaying
        snapshot.sourceBundleID = browser.bundleID
        snapshot.capturedAt = capturedAt
        return snapshot
    }

    /// Whether `new` differs from `old` only by the clock, and `old`'s
    /// projection still lands within `tolerance` of the new reading. Such a
    /// read changes nothing on screen, so it is not published: a poll every
    /// few seconds would otherwise re-render the notch every few seconds.
    static func isClockOnlyChange(_ new: NowPlaying, from old: NowPlaying,
                                  at date: Date, tolerance: TimeInterval = 1.0) -> Bool {
        var aligned = new
        aligned.elapsed = old.elapsed
        guard aligned == old else { return false }
        guard let newElapsed = new.elapsed, let projected = old.elapsedNow(at: date) else {
            return new.elapsed == nil && old.elapsed == nil
        }
        return abs(newElapsed - projected) < tolerance
    }

    /// Picks the tab to follow: the one playing, then the one already
    /// followed, then the first with a track loaded.
    static func choose(_ candidates: [(tab: YouTubeMusicTab, state: YouTubeMusicPageState)],
                       current: YouTubeMusicTab?) -> (tab: YouTubeMusicTab, state: YouTubeMusicPageState)? {
        let loaded = candidates.filter { $0.state.title != nil || $0.state.artist != nil }
        return loaded.first { $0.state.isPlaying }
            ?? loaded.first { $0.tab == current }
            ?? loaded.first
    }
}
