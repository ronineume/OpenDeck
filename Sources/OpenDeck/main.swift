import AppKit

// Entry point. A plain AppKit run loop gives us full control over the
// borderless overlay window, global hotkeys and event taps.
MainActor.assumeIsolated {
    // Declared before the first branch, so the flag is already set when a tool
    // reaches `DeckSettings.shared` — that initialiser writes preferences and
    // registers a login item, neither of which a development run may do to the
    // user's real install.
    AppEnvironment.isHeadless = CommandLine.arguments.contains {
        ["--selftest", "--bench", "--snapshot"].contains($0)
    }

    // Development aid: measure page-switch cost and exit.
    if let index = CommandLine.arguments.firstIndex(of: "--bench") {
        let frames = index + 1 < CommandLine.arguments.count
            ? (Int(CommandLine.arguments[index + 1]) ?? 40) : 40
        BenchRunner.run(frames: frames)
    }

    // Development aid: verify logic headlessly and exit.
    if CommandLine.arguments.contains("--selftest") {
        exit(SelfTest.run())
    }

    // Development aid: render the deck to a PNG and exit.
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
       index + 1 < CommandLine.arguments.count {
        SnapshotRunner.run(outputPath: CommandLine.arguments[index + 1])
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
