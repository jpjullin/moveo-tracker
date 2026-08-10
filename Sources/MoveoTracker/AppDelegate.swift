import AppKit
import MoveoTrackerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let persistence = SettingsPersistence()
    private var tracker: TrackerController!
    private var mainWindowController: MainWindowController!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var startMenuItem: NSMenuItem!
    private var stopMenuItem: NSMenuItem!
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastMenuSignature = ""
    private var quitAlert: NSAlert?
    private var quitCountdownTimer: Timer?
    private var quitConfirmationActive = false
    private var quitApproved = false
    private var lastDiagnosticsSignature = ""
    private var recoveryAttentionActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let previousSessionWasInterrupted = Diagnostics.shared.beginSession()

        let settings = persistence.load()
        tracker = TrackerController(settings: settings)
        mainWindowController = MainWindowController(
            settings: settings,
            previewSession: tracker.previewSession
        )
        wireCallbacks()
        installStatusItem()
        tracker.refreshCameras()
        installWorkspaceObservers()
        showWindow(nil)
        if previousSessionWasInterrupted {
            createAndPresentDiagnosticsArchive()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        tracker.shutdown()
        Diagnostics.shared.endSession()
    }

    func applicationDidHide(_ notification: Notification) {
        mainWindowController.updatePreviewVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        mainWindowController.updatePreviewVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitApproved { return .terminateNow }
        if !quitConfirmationActive { presentQuitConfirmation() }
        return .terminateLater
    }

    private func wireCallbacks() {
        mainWindowController.onStart = { [weak self] in self?.tracker.start() }
        mainWindowController.onStop = { [weak self] in self?.tracker.stop() }
        mainWindowController.onRefreshCameras = { [weak self] in self?.tracker.refreshCameras() }
        mainWindowController.onSettingsChanged = { [weak self] settings in
            self?.tracker.updateSettings(settings)
        }
        mainWindowController.onSave = { [weak self] settings in
            guard let self else { return }
            try self.persistence.save(settings)
        }
        mainWindowController.onReset = { [weak self] in
            self?.persistence.reset() ?? .defaults
        }
        mainWindowController.onPreviewVisibilityChanged = { [weak self] visible in
            self?.tracker.setPreviewPublishingEnabled(visible)
        }
        mainWindowController.onHide = { [weak self] in self?.hideWindow() }
        mainWindowController.onQuit = { [weak self] in self?.requestQuit() }
        tracker.onCameras = { [weak self] cameras in
            self?.mainWindowController.setCameras(cameras)
        }
        tracker.onPreviewOverlay = { [weak self] frame in
            self?.mainWindowController.updatePreviewOverlay(frame)
        }
        tracker.onStatus = { [weak self] status in
            self?.mainWindowController.update(status: status)
            self?.updateMenu(status: status)
            self?.recordDiagnostics(status: status)
            self?.showRecoveryIfNeeded(status: status)
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "hand.raised.fill",
                accessibilityDescription: "Moveo Tracker"
            )
            button.toolTip = "Moveo Tracker"
        }

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Tracking: idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindow(_:)), keyEquivalent: ""))
        startMenuItem = NSMenuItem(title: "Start", action: #selector(startTracking(_:)), keyEquivalent: "")
        stopMenuItem = NSMenuItem(title: "Stop", action: #selector(stopTracking(_:)), keyEquivalent: "")
        stopMenuItem.isEnabled = false
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tracker.systemWillSleep()
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tracker.systemDidWake()
        })
    }

    private func updateMenu(status: TrackerStatus) {
        let signature = "\(status.state)|\(status.isTracking)"
        guard signature != lastMenuSignature else { return }
        lastMenuSignature = signature
        statusMenuItem.title = "Tracking: \(status.state.lowercased())"
        startMenuItem.isEnabled = !status.isTracking
        stopMenuItem.isEnabled = status.isTracking
        statusItem.button?.toolTip = "Moveo Tracker - \(status.state)"
    }

    private func recordDiagnostics(status: TrackerStatus) {
        let signature = "\(status.state)|\(status.error)"
        guard signature != lastDiagnosticsSignature else { return }
        lastDiagnosticsSignature = signature
        let error = status.error.isEmpty ? "none" : status.error
        Diagnostics.shared.record("Tracker state: \(status.state) | error: \(error)")
    }

    private func showRecoveryIfNeeded(status: TrackerStatus) {
        let attentionStates = ["Waiting for camera", "Interrupted", "Recovering", "Error"]
        let needsAttention = attentionStates.contains(status.state)
        guard needsAttention else {
            recoveryAttentionActive = false
            return
        }
        guard !recoveryAttentionActive else { return }
        recoveryAttentionActive = true
        guard mainWindowController.window?.isVisible != true || NSApp.isHidden else { return }
        showWindow(nil)
    }

    private func createAndPresentDiagnosticsArchive() {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Diagnostics.shared.makeArchive() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Moveo Tracker may have crashed"
                switch result {
                case .success(let archiveURL):
                    alert.informativeText = "The previous session did not close normally. Please send the diagnostic ZIP to \(Diagnostics.supportEmail).\n\n\(archiveURL.path)"
                    alert.addButton(withTitle: "Show ZIP")
                    alert.addButton(withTitle: "Copy Email")
                    alert.addButton(withTitle: "Dismiss")
                    guard let window = self.mainWindowController.window else { return }
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertFirstButtonReturn {
                            NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                        } else if response == .alertSecondButtonReturn {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Diagnostics.supportEmail, forType: .string)
                        }
                    }
                case .failure(let error):
                    alert.informativeText = "The previous session did not close normally. A diagnostic ZIP could not be created (\(error.localizedDescription)). Please contact \(Diagnostics.supportEmail)."
                    alert.addButton(withTitle: "Copy Email")
                    alert.addButton(withTitle: "Dismiss")
                    guard let window = self.mainWindowController.window else { return }
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertFirstButtonReturn {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Diagnostics.supportEmail, forType: .string)
                        }
                    }
                }
            }
        }
    }

    @objc private func showWindow(_ sender: Any?) {
        NSApp.unhide(nil)
        mainWindowController.showWindow(nil)
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startTracking(_ sender: Any?) {
        tracker.start()
    }

    @objc private func stopTracking(_ sender: Any?) {
        tracker.stop()
    }

    @objc private func quit(_ sender: Any?) {
        requestQuit()
    }

    private func hideWindow() {
        mainWindowController.window?.orderOut(nil)
        // Return from the click event first so AppKit can commit the visual hide.
        // Detaching AVCaptureVideoPreviewLayer can synchronously wait on
        // AVFoundation and must not delay the window disappearing.
        DispatchQueue.main.async { [weak self] in
            self?.mainWindowController.updatePreviewVisibility()
        }
    }

    private func requestQuit() {
        NSApp.terminate(nil)
    }

    private func presentQuitConfirmation() {
        quitConfirmationActive = true
        NSApp.unhide(nil)
        mainWindowController.showWindow(nil)
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Moveo Tracker?"
        alert.informativeText = "Tracking and OSC output will stop when the app quits."
        let quitButton = alert.addButton(withTitle: "Quit in 5")
        quitButton.isEnabled = false
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        quitAlert = alert

        var remaining = 5
        quitCountdownTimer?.invalidate()
        let countdownTimer = Timer(timeInterval: 1, repeats: true) {
            [weak self, weak quitButton] timer in
            guard self != nil, let quitButton else {
                timer.invalidate()
                return
            }
            remaining -= 1
            if remaining > 0 {
                quitButton.title = "Quit in \(remaining)"
            } else {
                timer.invalidate()
                quitButton.title = "Quit"
                quitButton.isEnabled = true
                quitButton.keyEquivalent = "\r"
            }
        }
        quitCountdownTimer = countdownTimer
        RunLoop.main.add(countdownTimer, forMode: .common)

        guard let window = mainWindowController.window else {
            finishQuitConfirmation(shouldQuit: false)
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.finishQuitConfirmation(shouldQuit: response == .alertFirstButtonReturn)
        }
    }

    private func finishQuitConfirmation(shouldQuit: Bool) {
        quitCountdownTimer?.invalidate()
        quitCountdownTimer = nil
        quitAlert = nil
        quitConfirmationActive = false
        quitApproved = shouldQuit
        NSApp.reply(toApplicationShouldTerminate: shouldQuit)
    }
}
