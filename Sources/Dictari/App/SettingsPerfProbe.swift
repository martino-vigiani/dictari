#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// Development harness that measures how smoothly the Settings window animates.
///
///   DICTARI_SETTINGS_PERF=/path/out.json /path/to/Dictari.app/Contents/MacOS/Dictari
///
/// It starts no services (no event tap, no microphone, no MCP listener), hosts the real
/// `SettingsRootView` in a borderless window parked so that only two pixels sit on screen —
/// enough for the window server to keep it unoccluded and the display link ticking, without
/// covering anything the user is working in — then walks every section with the real page
/// transition and scrolls each page. Frame gaps seen by the display link are hitches: the
/// main thread was too busy to produce that frame. Writes JSON and exits.
@MainActor
final class SettingsPerfProbe: NSObject {
    static var outputPath: String? { ProcessInfo.processInfo.environment["DICTARI_SETTINGS_PERF"] }
    /// DICTARI_SETTINGS_SNAPSHOT=/dir renders every page (and its scrolled-down screens) to PNG
    /// instead of measuring — for checking translations without opening the app on screen:
    ///   DICTARI_SETTINGS_SNAPSHOT=/tmp/de …/Dictari -AppleLanguages '(de)'
    static var snapshotDirectory: String? { ProcessInfo.processInfo.environment["DICTARI_SETTINGS_SNAPSHOT"] }
    static var isRequested: Bool { outputPath != nil || snapshotDirectory != nil }

    static let selectNotification = Notification.Name("DictariSettingsPerfSelect")

    private struct Phase: Codable {
        var section: String
        var kind: String          // "switch" or "scroll"
        var frames: Int
        var hitches: Int          // frames that arrived ≥ 1.5 intervals late
        var hitchMs: Double       // time lost beyond the expected interval
        var maxGapMs: Double
        var durationMs: Double
        var cpuMs: Double = 0     // main-thread CPU time spent in the phase
        var scrollViews: String = ""
    }

    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    private let coordinator: AppCoordinator
    private var window: NSWindow?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var interval: CFTimeInterval = 1.0 / 60
    private var recording = false
    private var gaps: [Double] = []
    private var scrollStep: CGFloat = 0
    private var scrollView: NSScrollView?
    private var phases: [Phase] = []

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func run() {
        let size = Metrics.settingsWindow
        let root = SettingsRootView(initialSection: .home)
            .environment(coordinator)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        // Same as the real window: History's intrinsic height must not resize it.
        hosting.sizingOptions = []
        // The real window's chrome: a transparent, full-size-content title bar. The sidebar
        // and pages lay out against its safe area; a borderless window has none, so content
        // pushed under the traffic lights never showed in a snapshot.
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .floating
        let screen = NSScreen.main?.frame ?? .zero
        window.setFrameOrigin(NSPoint(x: screen.maxX - 2, y: screen.minY - size.height + 2))
        window.orderFrontRegardless()
        self.window = window

        let link = hosting.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link

        if let directory = Self.snapshotDirectory {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await snapshot(into: URL(fileURLWithPath: directory))
                exit(0)
            }
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            var order = SettingsSection.allCases.filter { $0 != .home } + [.home]
            // DICTARI_PERF_SEQUENCE=sound,library isolates one page's entry and exit cost.
            if let sequence = ProcessInfo.processInfo.environment["DICTARI_PERF_SEQUENCE"] {
                order = sequence.split(separator: ",").compactMap { SettingsSection(rawValue: String($0)) }
            }
            let cycles = Int(ProcessInfo.processInfo.environment["DICTARI_PERF_CYCLES"] ?? "") ?? 3
            for _ in 0..<cycles {
                for section in order {
                    await measureSwitch(to: section)
                    if ProcessInfo.processInfo.environment["DICTARI_PERF_NOSCROLL"] == nil {
                        await measureScroll(section)
                    }
                }
            }
            finish()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let expected = link.targetTimestamp - link.timestamp
        if expected > 0 { interval = expected }
        if recording, lastTimestamp > 0 { gaps.append(link.timestamp - lastTimestamp) }
        lastTimestamp = link.timestamp
        if scrollStep != 0, let scrollView {
            let clip = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            var y = clip.bounds.origin.y + scrollStep
            if y >= maxY || y <= 0 { scrollStep = -scrollStep; y = min(max(y, 0), maxY) }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func record(_ section: SettingsSection, kind: String, seconds: Double) async {
        gaps = []
        recording = true
        let start = CACurrentMediaTime()
        let cpu0 = Self.threadCPU()
        try? await Task.sleep(for: .seconds(seconds))
        recording = false
        let cpu = Self.threadCPU() - cpu0
        let late = gaps.filter { $0 >= interval * 1.5 }
        phases.append(Phase(
            section: section.rawValue, kind: kind, frames: gaps.count, hitches: late.count,
            hitchMs: late.reduce(0) { $0 + ($1 - interval) } * 1000,
            maxGapMs: (gaps.max() ?? 0) * 1000,
            durationMs: (CACurrentMediaTime() - start) * 1000, cpuMs: cpu))
    }

    private func measureSwitch(to section: SettingsSection) async {
        // Recording starts before the change so the frame that pays for building the page
        // is inside the window.
        gaps = []
        recording = true
        let start = CACurrentMediaTime()
        let cpu0 = Self.threadCPU()
        NotificationCenter.default.post(name: Self.selectNotification, object: section.rawValue)
        try? await Task.sleep(for: .milliseconds(700))
        recording = false
        let cpu = Self.threadCPU() - cpu0
        let late = gaps.filter { $0 >= interval * 1.5 }
        phases.append(Phase(
            section: section.rawValue, kind: "switch", frames: gaps.count, hitches: late.count,
            hitchMs: late.reduce(0) { $0 + ($1 - interval) } * 1000,
            maxGapMs: (gaps.max() ?? 0) * 1000,
            durationMs: (CACurrentMediaTime() - start) * 1000, cpuMs: cpu))
    }

    private func measureScroll(_ section: SettingsSection) async {
        guard let content = window?.contentView else { return }
        let all = Self.scrollViews(in: content).map {
            "\(Int($0.convert($0.bounds, to: nil).minX)):\(Int($0.contentView.bounds.height))/\(Int($0.documentView?.frame.height ?? -1))"
        }.joined(separator: ",")
        phases.append(Phase(section: section.rawValue, kind: "info", frames: 0, hitches: 0, hitchMs: 0,
                            maxGapMs: 0, durationMs: 0, scrollViews: all))
        // The detail column's scroll view: the widest one to the right of the sidebar.
        let candidates = Self.scrollViews(in: content).filter {
            $0.bounds.width > 400
                && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 40
        }
        guard let target = candidates.max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }) else { return }
        scrollView = target
        scrollStep = 6
        await record(section, kind: "scroll", seconds: 1.2)
        scrollStep = 0
        target.contentView.scroll(to: .zero)
        target.reflectScrolledClipView(target.contentView)
        scrollView = nil
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func snapshot(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let content = window?.contentView else { return }
        for (index, section) in SettingsSection.allCases.enumerated() {
            NotificationCenter.default.post(name: Self.selectNotification, object: section.rawValue)
            try? await Task.sleep(for: .milliseconds(1500))
            // No resize back to the window's size here: a page that grows the window (History
            // did, through its minimum height) must show up in the shots, not be hidden.
            content.layoutSubtreeIfNeeded()
            let scroll = Self.scrollViews(in: content).filter { $0.bounds.width > 400 }
                .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
            let pageHeight = scroll?.contentView.bounds.height ?? 0
            let documentHeight = scroll?.documentView?.frame.height ?? 0
            let screens = pageHeight > 0 ? min(4, max(1, Int((documentHeight / pageHeight).rounded(.up)))) : 1
            for screen in 0..<screens {
                if let scroll, screen > 0 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(screen) * (pageHeight - 60), documentHeight - pageHeight)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                write(directory.appendingPathComponent(String(format: "%02d-%@-%d.png", index, section.rawValue, screen + 1)))
            }
            if let scroll {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        // The sidebar scrolled part-way and to the end, where its rows meet the title bar.
        if let sidebar = Self.scrollViews(in: content).filter({ $0.convert($0.bounds, to: nil).minX < 10 })
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
            let maxY = max(0, (sidebar.documentView?.frame.height ?? 0) - sidebar.contentView.bounds.height)
            for (step, y) in [maxY / 2, maxY].enumerated() {
                sidebar.contentView.scroll(to: NSPoint(x: 0, y: y))
                sidebar.reflectScrolledClipView(sidebar.contentView)
                try? await Task.sleep(for: .milliseconds(500))
                write(directory.appendingPathComponent("99-sidebar-scrolled-\(step + 1).png"))
            }
        }
    }

    /// Draws the whole frame view, title bar and traffic lights included, not just the content.
    private func write(_ url: URL) {
        guard let frameView = window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    private func finish() {
        link?.invalidate()
        struct Output: Codable { var refreshHz: Double; var phases: [Phase] }
        let output = Output(refreshHz: (1 / interval).rounded(), phases: phases)
        if let path = Self.outputPath, let data = try? JSONEncoder().encode(output) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        exit(0)
    }
}
#endif
