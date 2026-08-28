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
        NSApp.activate(ignoringOtherApps: true)
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
    private let selection = SelectionOverlay()
    private let windowPicker = WindowPickerOverlay()
    private var statusItem: NSStatusItem?
    private var pickedWindow: SCWindow?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        StopHotkey.shared.install()
        StopHotkey.shared.onPress = { [weak self] in self?.stopRecording() }

        selection.onChange = { [weak self] rect in
            guard let self, self.settings.rememberSelection else { return }
            self.settings.savedRegion = rect
        }
        selection.onCommit = { [weak self] in self?.startRecording() }
        selection.onCancel = { [weak self] in self?.dismissCapture() }
        windowPicker.onCancel = { [weak self] in self?.dismissCapture() }
        windowPicker.onPick = { [weak self] window in
            guard let self else { return }
            self.pickedWindow = window
            self.windowPicker.close()
            self.startRecording()
        }

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
        windowPicker.close()
        bar.show()
    }

    @objc func showCaptureBar() { showCaptureUI() }

    private func showCaptureUI() {
        bar.show()
        applyMode()
    }

    func choose(source: CaptureSource?) {
        guard let source else {
            settings.audioOnly = true
            applyMode()
            return
        }
        settings.audioOnly = false
        settings.source = source
        applyMode()
    }

    private func applyMode() {
        guard !recorder.isBusy else { return }
        if settings.audioOnly {
            selection.hide()
            windowPicker.close()
            return
        }
        switch settings.source {
        case .region:
            windowPicker.close()
            selection.show(initial: settings.rememberSelection ? settings.savedRegion : nil)
        case .window:
            selection.hide()
            Task { await presentWindowPicker() }
        case .display, .app:
            selection.hide()
            windowPicker.close()
        }
    }

    private func presentWindowPicker() async {
        guard let content = try? await Recorder.shareableContent() else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != ownPID else { return false }
            return window.isOnScreen && window.frame.width > 60 && window.frame.height > 60
        }
        windowPicker.show(windows: windows)
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
            self.windowPicker.close()
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
        windowPicker.close()
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
        case .window:
            guard let picked = pickedWindow,
                  let fresh = content.windows.first(where: { $0.windowID == picked.windowID })
            else { return nil }
            return .window(fresh)
        case .app:
            guard let picked = pickedWindow, let app = picked.owningApplication, let display else { return nil }
            return .app(app, display)
        }
    }

    // MARK: Status item

    private func updateStatusItem(for state: RecorderState) {
        switch state {
        case .recording, .finishing:
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                             accessibilityDescription: "Stop Recording")
                item.button?.imagePosition = .imageLeading
                item.menu = statusMenu()
                statusItem = item
            }
            refreshStatusTitle()
        case .idle, .countdown:
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
    }

    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        button.title = " " + Self.timeString(recorder.elapsed)
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            .target = self
        let pause = menu.addItem(withTitle: recorder.isPaused ? "Resume" : "Pause",
                                 action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        return menu
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
        add(to: windowMenu, "Show Capture Bar", #selector(AppController.showCaptureBar),
            key: "1", modifiers: [.command], target: target)
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
