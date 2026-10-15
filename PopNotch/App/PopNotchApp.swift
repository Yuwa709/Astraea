//
//  PopNotchApp.swift
//  PopNotch
//
//  Created by Joshua Pham on 8/27/26.
//

import SwiftUI

extension Notification.Name {
    /// Asks AppDelegate to open Settings. Posted by the notch panel's gear.
    ///
    /// Two earlier routes are recorded here because both looked correct and
    /// neither worked. `NSApp.sendAction(Selector(("showSettingsWindow:")))`
    /// returns **true** while creating no window at all — measured
    /// 2026-08-30, so it reports success and does nothing.
    /// `@Environment(\.openSettings)` does work, but only inside the App's
    /// scene graph, which the panel is not in; hosting the observer in
    /// `MenuBarExtra`'s label fixed that until the icon became optional and
    /// took the observer with it.
    ///
    /// AppDelegate now owns the window outright, so this reaches something
    /// that exists for the whole session regardless of scenes.
    static let popNotchOpenSettings = Notification.Name("com.techie.PopNotch.openSettings")
}

@main
struct PopNotchApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Background agent (LSUIElement): no main window, ever. The notch
        // panel is created by AppDelegate; this menu bar item is the only
        // other UI surface.
        // Optional (see `showMenuBarIcon`), so nothing load-bearing may live
        // in here. Settings is owned by AppDelegate and Quit has a home in
        // the About tab; the pin has its button in the panel chrome.
        MenuBarExtra(isInserted: Binding(
            get: { appDelegate.settings.settings.showMenuBarIcon },
            set: { on in appDelegate.settings.update { $0.showMenuBarIcon = on } }
        )) {
            Button("Settings…") { appDelegate.showSettings() }
            Divider()
            Button("Quit PopNotch") { NSApp.terminate(nil) }
        } label: {
            Label("PopNotch", systemImage: "rectangle.topthird.inset.filled")
        }
    }
}
