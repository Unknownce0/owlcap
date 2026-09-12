import AppKit
import ScreenCaptureKit
import Combine

@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--check"), args.count > index + 1 {
            SelfTest.check(path: args[index + 1])
        }
        if let index = args.firstIndex(of: "--selftest") {
            let seconds = args.count > index + 1 ? (Double(args[index + 1]) ?? 6) : 6
            var region: CGRect?
            if let r = args.firstIndex(of: "--region"), args.count > r + 1 {
                let parts = args[r + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            }
            SelfTest.run(seconds: seconds,
                         includeMic: args.contains("--mic"),
                         audioOnly: args.contains("--audio-only"),
                         region: region)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        MainMenuBuilder.install(target: controller)
        controller.newScreenRecording()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller?.newScreenRecording()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.recorder.isRecording else { return .terminateNow }
        controller.stopRecording()
        // Give the writer a moment to close the file cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Controller

/// Ties the bar, the overlays, the menus and the recorder together. There is no
/// document and no settings window — the app is the capture bar.
@MainActor
final class AppController: NSObject {

    let recorder = Recorder()
    private let settings = Settings.shared
    private lazy var bar = CaptureBar(controller: self)
    private lazy var audioRecorder = AudioRecorderWindow(controller: self)
    private let selection = SelectionOverlay()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        Hotkeys.shared.onStop = { [weak self] in self?.stopRecording() }
        Hotkeys.shared.onSummon = { [weak self] in self?.toggleCaptureBar() }
        Hotkeys.shared.install()
        installStatusItem()

        selection.onChange = { [weak self] rect in
            guard let self, self.settings.rememberSelection else { return }
            self.settings.savedRegion = rect
        }
        selection.onCommit = { [weak self] in self?.startRecording() }
        selection.onCancel = { [weak self] in self?.dismissCapture() }

        recorder.$state
            .sink { [weak self] state in self?.updateStatusItem(for: state) }
            .store(in: &cancellables)
        recorder.$elapsed
            .sink { [weak self] _ in self?.refreshStatusTitle() }
            .store(in: &cancellables)
        recorder.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in self?.presentError(message) }
            .store(in: &cancellables)
    }

    // MARK: Entry points

    @objc func newScreenRecording() {
        guard !recorder.isBusy else { return }
        settings.audioOnly = false
        showCaptureUI()
    }

    @objc func newAudioRecording() {
        guard !recorder.isBusy else { return }
        settings.audioOnly = true
        selection.hide()
        bar.close()
        audioRecorder.show()
    }

    @objc func showCaptureBar() { showCaptureUI() }

    private func showCaptureUI() {
        bar.show()
        applyMode()
    }

    func choose(source: CaptureSource) {
        settings.audioOnly = false
        settings.source = source
        applyMode()
    }

    private func applyMode() {
        guard !recorder.isBusy else { return }
        if settings.audioOnly {
            selection.hide()
            return
        }
        switch settings.source {
        case .region:
            selection.show(initial: settings.rememberSelection ? settings.savedRegion : nil)
        case .display:
            selection.hide()
        }
    }

    // MARK: Recording

    @objc func startRecording() {
        guard !recorder.isBusy else { return }
        Task { @MainActor in
            guard let target = await self.currentTarget() else {
                self.presentError(RecorderError.noTarget.localizedDescription)
                return
            }
            self.bar.hide()
            self.selection.hide()
            self.recorder.start(target: target, settings: self.settings)
        }
    }

    @objc func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
    }

    @objc func togglePause() { recorder.togglePause() }

    @objc func dismissCapture() {
        selection.close()
        bar.close()
    }

    @objc func openLastRecording() {
        guard let url = recorder.lastOutput else { return }
        NSWorkspace.shared.open(url)
    }

    private func currentTarget() async -> CaptureTarget? {
        guard let content = try? await Recorder.shareableContent() else { return nil }
        let mainID = NSScreen.main?.displayID
        let display = content.displays.first { $0.displayID == mainID } ?? content.displays.first

        if settings.audioOnly { return .audioOnly(display) }

        switch settings.source {
        case .display:
            guard let display else { return nil }
            return .display(display)
        case .region:
            let rect = selection.selection ?? settings.savedRegion
            guard let rect, let (displayID, local) = ScreenGeometry.displayRelative(rect),
                  let target = content.displays.first(where: { $0.displayID == displayID })
            else { return nil }
            settings.displayID = displayID
            return .region(target, local)
        }
    }

    // MARK: Status item

    /// Lives in the menu bar for the whole session. This is the entry point that works
    /// from inside a fullscreen app: clicking a status item does not activate OwlCap, so
    /// macOS has no reason to switch you out of the Space you are in.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle",
                                     accessibilityDescription: "OwlCap")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "OwlCap — click to record (⌘⇧6)"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else if recorder.isRecording {
            stopRecording()
        } else {
            toggleCaptureBar()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        if recorder.isRecording {
            add(to: menu, "Stop Recording", #selector(stopRecording))
            add(to: menu, recorder.isPaused ? "Resume" : "Pause", #selector(togglePause))
        } else {
            add(to: menu, "New Screen Recording", #selector(newScreenRecording))
            add(to: menu, "New Audio Recording", #selector(newAudioRecording))
            if recorder.lastOutput != nil {
                menu.addItem(.separator())
                add(to: menu, "Open Last Recording", #selector(openLastRecording))
            }
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit OwlCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    /// Summoned by ⌘⇧6 or a click on the menu bar icon.
    @objc func toggleCaptureBar() {
        guard !recorder.isBusy else { return }
        if bar.isVisible {
            dismissCapture()
        } else {
            showCaptureUI()
        }
    }

    private func updateStatusItem(for state: RecorderState) {
        let recording = state == .recording || state == .finishing
        statusItem?.button?.image = NSImage(
            systemSymbolName: recording ? "stop.circle" : "record.circle",
            accessibilityDescription: recording ? "Stop Recording" : "OwlCap")
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = recording ? "Stop Recording (⌘⌃⎋)" : "OwlCap — click to record (⌘⇧6)"
    }

    private func refreshStatusTitle() {
        // The menu-bar item stays a bare stop button; the running time lives in the
        // audio recorder window, where QuickTime shows it too.
        audioRecorder.refresh()
    }

    private func presentError(_ message: String) {
        guard !message.isEmpty else { return }
        recorder.errorMessage = nil
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "OwlCap couldn't record"
        alert.informativeText = message
        alert.alertStyle = .warning
        if message.contains("Screen & System Audio Recording") {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = Recorder.requestScreenPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        } else {
            alert.runModal()
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Menu bar

enum MainMenuBuilder {
    @MainActor
    static func install(target: AppController) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OwlCap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OwlCap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit OwlCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(to: fileMenu, "New Screen Recording", #selector(AppController.newScreenRecording),
            key: "n", modifiers: [.control, .command], target: target)
        add(to: fileMenu, "New Audio Recording", #selector(AppController.newAudioRecording),
            key: "n", modifiers: [.shift, .command], target: target)
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Start Recording", #selector(AppController.startRecording),
            key: "r", modifiers: [.command], target: target)
        add(to: fileMenu, "Stop Recording", #selector(AppController.stopRecording),
            key: "\u{1b}", modifiers: [.command, .control], target: target)
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Open Last Recording", #selector(AppController.openLastRecording),
            key: "o", modifiers: [.command], target: target)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        add(to: windowMenu, "Show Capture Bar", #selector(AppController.toggleCaptureBar),
            key: "6", modifiers: [.command, .shift], target: target)
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @MainActor
    private static func add(to menu: NSMenu, _ title: String, _ action: Selector,
                            key: String, modifiers: NSEvent.ModifierFlags, target: AnyObject) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }
}
