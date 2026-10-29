// Synthetic visual QA, using the exact shipped WidgetKit view. No account files or network.
// xcrun swiftc -D TOKENBAR_WIDGET_PREVIEW -parse-as-library Shared/*.swift \
//   WidgetExtension/*.swift scripts/render-widget-previews.swift -o /tmp/tokenbar-widget-preview
// /tmp/tokenbar-widget-preview /absolute/output/directory
import AppKit
import SwiftUI
import WidgetKit

@main
enum RenderWidgetPreviews {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let date = Date(timeIntervalSince1970: 1_793_280_000)
        let fresh = TokenBarWidgetPreview.entry(at: date)
        let stale = TokenBarWidgetEntry(date: date.addingTimeInterval(180), snapshot: fresh.snapshot)
        var edges = fresh.snapshot
        for i in edges.accounts.indices {
            edges.accounts[i].urgencyWindow = nil
            let value = [0.0, 0.1, 19.9, 20, 99, 100][i]
            edges.accounts[i].metrics = [.init(id: "weekly", label: "每周", value: "\(value)%", remainingPercent: value),
                .init(id: "unknown", label: "5 小时", value: "—", remainingPercent: nil)]
        }
        var long = fresh.snapshot
        for i in long.accounts.indices {
            long.accounts[i].email = "long-account-label-\(i)@example.com"
            long.accounts[i].metrics[0].label = "每周 · Claude Sonnet"
        }
        let entries = [("fresh", fresh), ("stale", stale),
                       ("edges", TokenBarWidgetEntry(date: date, snapshot: edges)),
                       ("long", TokenBarWidgetEntry(date: date, snapshot: long)),
                       ("empty", TokenBarWidgetEntry(date: date, snapshot: .init(generatedAt: date, accounts: [])))]
        let families: [(String, WidgetFamily, CGFloat, CGFloat)] = [
            ("small", .systemSmall, 170, 170), ("medium", .systemMedium, 360, 170), ("large", .systemLarge, 360, 382)
        ]
        for (scenario, entry) in entries {
            for (name, family, width, height) in families {
                for scheme in [ColorScheme.light, .dark] {
                    let view = TokenBarWidgetView(entry: entry, familyOverride: family)
                        .frame(width: width - 32, height: height - 32, alignment: .topLeading)
                        .padding(16)
                        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.98))
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        fatalError("Could not render \(scenario) \(name)")
                    }
                    let filename = "\(scenario)-\(name)-\(scheme == .dark ? "dark" : "light").png"
                    try data.write(to: output.appendingPathComponent(filename))
                }
            }
        }
        print("Rendered 30 synthetic widget previews to \(output.path)")
    }
}
