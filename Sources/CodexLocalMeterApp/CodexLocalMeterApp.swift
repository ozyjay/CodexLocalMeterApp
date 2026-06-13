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

        Task { @MainActor in
            await model.start()
        }
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
        let level = StatusFormatter.statusLevel(summary: model.summary, settings: model.settings)
        button.image = StatusBarIcon.image(for: level)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: " \(model.menuBarValueText)",
            attributes: [
                .foregroundColor: StatusBarColors.textColor(for: level)
            ]
        )
        button.toolTip = "Codex Local Meter - \(model.menuBarValueText)"
        button.setAccessibilityLabel("Codex Local Meter")
        statusItem?.length = NSStatusItem.variableLength
        statusItem?.isVisible = true
        AppLog.write("status item updated title=\(model.menuBarValueText) level=\(level) hasImage=\(button.image != nil) length=\(statusItem?.length ?? -1)")
    }
}

enum StatusBarIcon {
    static func image(for level: StatusLevel) -> NSImage? {
        guard let image = baseImage?.copy() as? NSImage else {
            return nil
        }
        switch level {
        case .normal:
            image.isTemplate = true
            return image
        case .warning:
            return tintedImage(image, color: StatusBarColors.warning)
        case .danger:
            return tintedImage(image, color: StatusBarColors.danger)
        }
    }

    private static let baseImage: NSImage? = {
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

    private static func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}

enum StatusBarColors {
    static let warning = NSColor.systemOrange
    static let danger = NSColor.systemRed

    static func textColor(for level: StatusLevel) -> NSColor {
        switch level {
        case .normal:
            return .labelColor
        case .warning:
            return warning
        case .danger:
            return danger
        }
    }
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
    private lazy var refreshScheduler = RefreshScheduler<Void> { [weak self] in
        await self?.performRefresh()
    }
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
        await refreshScheduler.requestRefresh()
    }

    private func performRefresh() async {
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
    @State private var detailsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                heroSection
                if model.settings.showWeeklyUsage {
                    weeklySection
                }
                statusLine
                actions
                detailsSection
            }
            .padding(18)
        }
        .sheet(isPresented: $model.showingDiagnostics) {
            DiagnosticsView(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Codex Local Meter")
                .font(.headline)
            Text("Local estimates only. No session content leaves your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var heroSection: some View {
        HStack(alignment: .center, spacing: 20) {
            fiveHourGauge
                .frame(width: 134, height: 134)

            VStack(alignment: .leading, spacing: 8) {
                Text("5-hour window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(StatusFormatter.fiveHourDetail(summary: model.summary))
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    windowRemainingLabel(duration: 5 * 60 * 60, now: context.date)
                }
                Text(heroSupportText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var fiveHourGauge: some View {
        if let percent = model.summary.primaryUsedPercent {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: clamped(percent) / 100)
                    .stroke(statusColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 3) {
                    Text("5-hour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(UsageFormatting.percent(percent))%")
                        .font(.title.weight(.bold))
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("5-hour rate limit")
            .accessibilityValue("\(UsageFormatting.percent(percent)) percent used")
        } else {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 14)
                VStack(spacing: 3) {
                    Text(model.summary.isEstimated ? "Est." : "Local")
                        .font(.headline)
                    Text(estimatedGaugeValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(18)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("5-hour usage estimate")
            .accessibilityValue(estimatedGaugeValue)
        }
    }

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("7-day window", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(StatusFormatter.sevenDayDetail(summary: model.summary))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                windowRemainingLabel(duration: 7 * 24 * 60 * 60, now: context.date)
            }
            ProgressView(value: weeklyProgress)
                .tint(.blue)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Label(statusText, systemImage: statusSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
            Spacer()
            Label(UsageFormatting.relativeTime(model.summary.lastActivity), systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)

            Button {
                model.chooseCodexFolder()
            } label: {
                Label("Folder", systemImage: "folder")
            }

            Button {
                model.showDiagnostics()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .controlSize(.small)
    }

    private var detailsSection: some View {
        DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                detailMetrics
                sourceDetails
                issuesSection
                settingsSection
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private var detailMetrics: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            detailRow("Sessions (7 d)", "\(model.summary.sessionCount)")
            detailRow("Models", model.summary.modelNames.isEmpty ? "-" : model.summary.modelNames.joined(separator: ", "))
            if !model.settings.showWeeklyUsage {
                detailRow("7-day window", StatusFormatter.sevenDayDetail(summary: model.summary))
            }
        }
    }

    private var sourceDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            detailRow("Codex path", model.summary.codexPath)
            detailRow("Token counts", model.summary.isEstimated ? "Not found - using message counts" : "Found")
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

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Seconds", text: $model.refreshIntervalText)
                    .frame(width: 72)
                Text("sec")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Apply") {
                    model.applySettings()
                }
            }
            Toggle("Compact menu bar", isOn: $model.compactMode)
                .font(.caption)
        }
    }

    private var statusLevel: StatusLevel {
        StatusFormatter.statusLevel(summary: model.summary, settings: model.settings)
    }

    private var statusText: String {
        switch statusLevel {
        case .normal:
            return "Normal"
        case .warning:
            return "Warning"
        case .danger:
            return "Limit high"
        }
    }

    private var statusSymbol: String {
        switch statusLevel {
        case .normal:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .danger:
            return "exclamationmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch statusLevel {
        case .normal:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }

    private var heroSupportText: String {
        if model.summary.primaryUsedPercent != nil {
            return "Based on the latest local Codex rate-limit event."
        }
        if model.summary.sessionCount == 0 && model.summary.parseErrors.isEmpty {
            return "No recent local session activity found."
        }
        return model.summary.isEstimated ? "Using local message counts until rate-limit data appears." : "Using local token counts."
    }

    private var estimatedGaugeValue: String {
        if model.summary.isEstimated {
            return "~\(model.summary.fiveHourMessages ?? 0) msgs"
        }
        return UsageFormatting.tokens(model.summary.fiveHourTokens) ?? "0 tokens"
    }

    private var weeklyProgress: Double {
        clamped(model.summary.secondaryUsedPercent ?? 0) / 100
    }

    private func clamped(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }

    private func windowRemainingLabel(duration: TimeInterval, now: Date) -> some View {
        Label(
            UsageFormatting.windowRemaining(
                lastActivity: model.summary.lastActivity,
                duration: duration,
                now: now
            ),
            systemImage: "timer"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(value)
                .font(.caption)
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
