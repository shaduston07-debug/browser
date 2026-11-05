// swift-tools-version: 5.9

// Inkwell — a desktop-class browser for iPad with real web-extension support.
// Open this folder (InkwellBrowser.swiftpm) in Swift Playgrounds on iPad, or in Xcode on a Mac.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "InkwellBrowser",
    platforms: [
        // WKWebExtension (the API that runs Chrome/Safari/Firefox-style extensions) requires iPadOS 18.4+.
        .iOS("18.4")
    ],
    products: [
        .iOSApplication(
            name: "Inkwell",
            targets: ["AppModule"],
            bundleIdentifier: "com.mangashaduston.inkwellbrowser",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .map),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources"
        )
    ]
)
