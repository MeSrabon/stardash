import AppKit
import SwiftUI

let arguments = CommandLine.arguments

if let i = arguments.firstIndex(of: "--icon"), i + 2 < arguments.count {
    MainActor.assumeIsolated { IconMaker.write(to: arguments[i + 1], from: arguments[i + 2]) }
} else if arguments.contains("--speedtest") {
    Task { @MainActor in
        await SpeedProbe.run()
        exit(0)
    }
    RunLoop.main.run()
} else if arguments.contains("--ping") {
    // Checks the ICMP pinger on its own. Sends 50 small pings to 1.1.1.1.
    if let r = Pinger.run() {
        print(String(format: "sent %d, received %d, loss %.1f%%, median %.1f ms, jitter %.2f ms",
                     r.sent, r.received, r.loss * 100, r.median ?? -1, r.jitter ?? -1))
    } else {
        print("couldn't open a ping socket")
    }
} else if arguments.contains("--probe") {
    // Prints what the dish and router report, for checking a setup without the UI.
    Task { @MainActor in
        await Probe.run()
        exit(0)
    }
    RunLoop.main.run()
} else if let i = arguments.firstIndex(of: "--export-debug"), i + 1 < arguments.count {
    // Writes the same file as Device › Export debug data, without the UI.
    Task { @MainActor in
        let store = TelemetryStore()
        store.popoverOpen = true
        try? await Task.sleep(for: .seconds(6))
        do {
            try DebugExport.data(store).write(to: URL(fileURLWithPath: arguments[i + 1]), options: .atomic)
            print("wrote \(arguments[i + 1])")
        } catch {
            print("export failed: \(error)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    // Renders every tab to PNG with live data. Used to check the UI without screen recording access.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        await Snapshot.run(directory: arguments[i + 1])
        exit(0)
    }
    app.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // run() never returns, which keeps the delegate alive.
        app.run()
    }
}
