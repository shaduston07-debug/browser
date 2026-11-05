# Inkwell — a desktop-class browser for iPad

Inkwell makes an iPad (built for the M4 iPad Pro/Air) behave like a Mac browser:

- **Real browser extensions.** Install extensions straight from the **Chrome Web Store** or **Firefox Add-ons** with the **Add to Inkwell** button, or import `.crx` / `.xpi` / `.zip` files and unpacked folders. They run on WebKit's built-in Web Extensions engine (`WKWebExtension`, the same one Safari uses). That covers content scripts, toolbar buttons with popups and badges, background service workers, `storage`, `tabs`, `windows`, `scripting`, `contextMenus`, `declarativeNetRequest`, `cookies`, options pages, and more.
- **Desktop websites, always.** Every page loads in desktop mode with a Mac user agent (Safari, Chrome, Edge or Firefox on Mac). An optional setting hides the touch screen from sites so they don't switch to an iPad layout.
- **Mac-style window.** A tab strip, a toolbar with the extension buttons, a bookmarks bar, right-click menus (with extensions' context-menu items), multiple windows, and session restore.
- **Keyboard shortcuts.** Hold ⌘ to see them all:

| Shortcut | Action | Shortcut | Action |
|---|---|---|---|
| ⌘T | New tab | ⌘W | Close tab |
| ⌘⇧T | Reopen closed tab | ⌘N | New window |
| ⌘L | Address bar | ⌘R / ⌘⌥R | Reload / without cache |
| ⌘[ ⌘] | Back / forward | ⌃Tab, ⌘⇧] ⌘⇧[ | Next / previous tab |
| ⌘1…⌘9 | Jump to tab | ⌘F | Find on page |
| ⌘+ ⌘- ⌘0 | Zoom | ⌘D | Bookmark page |
| ⌘⇧B | Bookmarks bar | ⌘⇧E | Extensions |
| ⌘, | Settings | ⌘Y | History |
| Esc | Stop / leave address bar | | |

- **Everyday browser features.** History (⌘Y) with search, address-bar suggestions from your history and bookmarks (use ↑/↓ and Return), a new-tab page with Favourites and Frequently Visited, favicons in tabs, and press-and-hold Back/Forward for page history.
- **Downloads.** Downloaded files can be saved to Files or shared. `.crx` and `.xpi` files offer to install themselves.
- **Developer tools.** Every page and extension can be inspected with Web Inspector from Safari on a Mac.

## Requirements

- iPadOS **18.4 or later** (this is when Apple added the extension API). iPadOS 26 is recommended.
- **Swift Playgrounds** (free, App Store) on the iPad, **or** Xcode 16.3+ on a Mac.

## Building and running on the iPad (no Mac needed)

1. On the iPad, open this repository on GitHub in Safari and choose **Code → Download ZIP**.
2. In the **Files** app, tap the ZIP to unpack it.
3. Open **`InkwellBrowser.swiftpm`** in **Swift Playgrounds**.
4. Tap **▶︎ Run**, then tap the expand button (↗↙) in the App Preview panel so the app fills the screen.

Swift Playgrounds can't put an app on the home screen. To get a real home-screen app, either upload it to TestFlight from Playgrounds (this needs a paid Apple Developer account) or build it with Xcode on a Mac (see below; a free Apple ID works, but the app has to be re-signed every 7 days).

## Building with Xcode on a Mac

Open `InkwellBrowser.swiftpm` in Xcode, select your iPad as the run destination, set your signing team, and press ⌘R.

## Installing extensions

- **Chrome Web Store:** open the puzzle-piece menu and choose **Chrome Web Store**. Find an extension and tap **Add to Inkwell** in the toolbar. (The page's own "Add to Chrome" button won't work. Use the toolbar button instead.)
- **Firefox Add-ons:** do the same from **Firefox Add-ons**.
- **Files:** go to **Extensions… → Import .zip, .crx or .xpi…** or **Load Unpacked Folder…**.
- **Updates:** go to **Extensions… → Update Store Extensions**. Updating keeps each extension's settings and data.

Before an extension is added, a dialog shows which sites and permissions it wants, the way desktop Chrome does. Later permission requests are also confirmed in a dialog.

## Limits you should know about

These come from Apple's platform rules, not from Inkwell:

- **Every iOS browser has to use WebKit.** Inkwell renders like Safari, not like Chrome's Blink engine. (In the EU, Apple allows other engines, but only for apps with a special entitlement.)
- **Extension APIs are the ones WebKit implements.** Most popular extensions work, including password managers, Dark Reader, uBlock Origin Lite, Grammarly-style content scripts, tab managers, and Tampermonkey-style userscript managers. These don't work:
  - Blocking `webRequest`. This is why full **uBlock Origin** (MV2) can't block. Use **uBlock Origin Lite** instead.
  - `chrome.debugger`, native messaging, `sidePanel`, and Chrome-only APIs such as `chrome.identity` sign-in flows.
- **No persistent background pages.** iPadOS suspends extension backgrounds, so MV2 extensions with `"persistent": true` may behave differently. MV3 service workers are fine.
- **Windows opened by extensions** (`chrome.windows.create`) open as tabs in the current window, because iPadOS can't create a window synchronously.

## Project layout

```
InkwellBrowser.swiftpm/
  Package.swift                 iOS app definition (Swift Playgrounds / Xcode)
  Sources/
    InkwellApp.swift            App entry; one BrowserWindow per iPad window
    History.swift               History, favicons, ⌘Y history window, new-tab start page
    BrowserWindow.swift         Tab strip, toolbar, shortcuts, WebKit delegates, WKWebExtensionWindow
    BrowserTab.swift            WKWebView tab (WKWebExtensionTab), window registry, session, bookmarks, downloads
    ExtensionManager.swift      WKWebExtensionController, install/update/remove, store downloads, permission prompts
    ExtensionsView.swift        "Manage Extensions" sheet
    ChromeViews.swift           Tab strip, extension toolbar button, bookmarks bar
    Settings.swift              Search engine, user agent, desktop-mode options
    ZipArchive.swift            Dependency-free .zip/.crx/.xpi unpacker
```
