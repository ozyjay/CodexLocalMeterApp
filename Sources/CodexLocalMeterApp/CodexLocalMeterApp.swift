import AppKit
import Combine
import CodexLocalMeterCore
import SwiftUI

@main
struct CodexLocalMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: MeterViewModel?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        AppLog.write("activationPolicy=accessory")

        let model = MeterViewModel()
        self.model = model
        AppLog.write("model created with menuBarValueText=\(model.menuBarValueText)")

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MeterPopoverView(model: model)
                .frame(width: 420)
        )
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "local.codex-meter.CodexLocalMeter.statusItem"
        item.isVisible = true
        self.statusItem = item
        AppLog.write("status item created; hasButton=\(item.button != nil)")
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Codex Local Meter"
            AppLog.write("status button configured")
        }
        updateStatusItem()

        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.write("applicationShouldHandleReopen visibleWindows=\(flag)")
        Task { @MainActor in
            await model?.refresh()
            showPopover()
        }
        return false
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else {
            return
        }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let model else {
            AppLog.write("updateStatusItem skipped; button/model missing")
            return
        }
        button.image = StatusBarIcon.image
        button.imagePosition = .imageLeading
        button.title = " \(model.menuBarValueText)"
        button.toolTip = "Codex Local Meter - \(model.menuBarValueText)"
        button.setAccessibilityLabel("Codex Local Meter")
        statusItem?.length = max(96, button.attributedTitle.size().width + 18)
        statusItem?.isVisible = true
        AppLog.write("status item updated title=\(model.menuBarValueText) hasImage=\(button.image != nil) length=\(statusItem?.length ?? -1)")
    }
}

enum StatusBarIcon {
    static let image: NSImage? = {
        let bundles: [Bundle] = [Bundle.main, Bundle.module]
        for bundle in bundles {
            if let url = bundle.url(forResource: "status-icon", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.size = NSSize(width: 16, height: 16)
                return image
            }
        }
        return nil
    }()
}

@MainActor
final class MeterViewModel: ObservableObject {
    @Published private(set) var summary = UsageSummary(
        isEstimated: true,
        codexPath: MeterSettings.defaults.codexPath,
        sessionCount: 0,
        modelNames: [],
        parseErrors: []
    )
    @Published var settings: MeterSettings
    @Published private(set) var isRefreshing = false
    @Published var diagnosticsText = ""
    @Published var showingDiagnostics = false
    @Published var refreshIntervalText: String
    @Published var compactMode: Bool

    private let settingsStore: SettingsStore
    private var timer: Timer?
    private var watcher: DirectoryWatcher?
    private var started = false

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        settings = loaded
        refreshIntervalText = String(Int(loaded.refreshIntervalSeconds))
        compactMode = loaded.compactMode
        summary = UsageSummary(
            isEstimated: true,
            codexPath: loaded.codexPath,
            sessionCount: 0,
            modelNames: [],
            parseErrors: []
        )
        Task { @MainActor in
            await start()
        }
    }

    var menuBarValueText: String {
        let text = StatusFormatter.statusText(summary: summary, settings: settings)
        return text.isEmpty ? "--" : text
    }

    func start() async {
        guard !started else {
            return
        }
        started = true
        AppLog.write("model start")
        await refresh()
        restartTimer()
        restartWatcher()
    }

    func refresh() async {
        AppLog.write("refresh start path=\(settings.codexPath)")
        isRefreshing = true
        let currentSettings = settings
        let result = await Task.detached {
            await CodexReader().readEvents(codexPath: currentSettings.codexPath)
        }.value
        summary = UsageCalculator().calculate(
            events: result.events,
            codexPath: currentSettings.codexPath,
            parseErrors: result.parseErrors
        )
        isRefreshing = false
        AppLog.write("refresh complete menuBarValueText=\(menuBarValueText) sessions=\(summary.sessionCount) errors=\(summary.parseErrors.count)")
    }

    func chooseCodexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Codex Folder"
        panel.directoryURL = URL(fileURLWithPath: settings.codexPath)

        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.saveCodexPath(url.path)
            reloadSettings()
            Task { await refresh() }
            restartWatcher()
        }
    }

    func applySettings() {
        if let seconds = Double(refreshIntervalText) {
            settingsStore.saveRefreshIntervalSeconds(seconds)
        }
        settingsStore.saveCompactMode(compactMode)
        reloadSettings()
        restartTimer()
        Task { await refresh() }
    }

    func showDiagnostics() {
        diagnosticsText = DiagnosticsReporter.report(summary: summary)
        showingDiagnostics = true
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText, forType: .string)
    }

    private func reloadSettings() {
        settings = settingsStore.load()
        refreshIntervalText = String(Int(settings.refreshIntervalSeconds))
        compactMode = settings.compactMode
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private func restartWatcher() {
        watcher = DirectoryWatcher(path: URL(fileURLWithPath: settings.codexPath).appendingPathComponent("sessions").path) { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }
}

final class DirectoryWatcher {
    private var descriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}

struct MeterPopoverView: View {
    @ObservedObject var model: MeterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            usageSection
            activitySection
            sourceSection
            issuesSection
            actions
            settingsSection
        }
        .padding(18)
        .sheet(isPresented: $model.showingDiagnostics) {
            DiagnosticsView(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Codex Local Meter")
                .font(.headline)
            Text("Local estimates from Codex session files")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var usageSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("5-hour window", StatusFormatter.fiveHourDetail(summary: model.summary))
            if model.settings.showWeeklyUsage {
                row("7-day window", StatusFormatter.sevenDayDetail(summary: model.summary))
            }
        }
    }

    private var activitySection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Last activity", UsageFormatting.relativeTime(model.summary.lastActivity))
            row("Sessions (7 d)", "\(model.summary.sessionCount)")
            row("Models", model.summary.modelNames.isEmpty ? "-" : model.summary.modelNames.joined(separator: ", "))
        }
    }

    private var sourceSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Codex path", model.summary.codexPath)
            row("Token counts", model.summary.isEstimated ? "Not found - using message counts" : "Found")
        }
    }

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parse issues (\(model.summary.parseErrors.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.summary.parseErrors.isEmpty {
                Text("None")
                    .font(.caption)
            } else {
                ForEach(model.summary.parseErrors.prefix(4), id: \.self) { issue in
                    Text(issue)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .disabled(model.isRefreshing)

            Button("Choose Folder") {
                model.chooseCodexFolder()
            }

            Button("Diagnostics") {
                model.showDiagnostics()
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Seconds", text: $model.refreshIntervalText)
                    .frame(width: 72)
                Text("seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Compact", isOn: $model.compactMode)
                Button("Apply") {
                    model.applySettings()
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: MeterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    model.copyDiagnostics()
                }
            }
            ScrollView {
                Text(model.diagnosticsText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 640, height: 520)
    }
}
