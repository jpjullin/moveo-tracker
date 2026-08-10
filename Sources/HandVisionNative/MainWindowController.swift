import AppKit
import AVFoundation
import HandVisionCore

final class MainWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onRefreshCameras: (() -> Void)?
    var onSettingsChanged: ((AppSettings) -> Void)?
    var onSave: ((AppSettings) throws -> Void)?
    var onReset: (() -> AppSettings)?
    var onPreviewVisibilityChanged: ((Bool) -> Void)?
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?

    private var settings: AppSettings
    private var cameras: [CameraChoice] = []
    private var previewIsVisible = false
    private var latestStatus = TrackerStatus()

    private let cameraPopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let handsPopup = NSPopUpButton()
    private let cadencePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let zoomValueLabel = NSTextField(labelWithString: "1.00x")
    private let rotationSlider = NSSlider(value: 0, minValue: 0, maxValue: 359.99, target: nil, action: nil)
    private let rotationField = NSTextField(string: "0")
    private let hostField = NSTextField(string: "127.0.0.1")
    private let portField = NSTextField(string: "9000")
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let hideButton = NSButton(title: "Hide", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    private let stateValue = NSTextField(labelWithString: "Idle")
    private let cameraValue = NSTextField(labelWithString: "None")
    private let handsValue = NSTextField(labelWithString: "0")
    private let fpsValue = NSTextField(labelWithString: "0.0 fps")
    private let inferenceValue = NSTextField(labelWithString: "0.0 ms")
    private let dropsValue = NSTextField(labelWithString: "0")
    private let oscValue = NSTextField(labelWithString: "127.0.0.1:9000")
    private let processCPUValue = NSTextField(labelWithString: "Paused")
    private let processRAMValue = NSTextField(labelWithString: "Paused")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let previewView: CameraPreviewView
    private let metricsSampler = ProcessMetricsSampler()

    init(settings: AppSettings, previewSession: AVCaptureSession) {
        self.settings = settings
        self.previewView = CameraPreviewView(session: previewSession)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 736),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hand Vision Native"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        applySettingsToControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updatePreviewVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        deferPreviewSuspension()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        deferPreviewSuspension()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updatePreviewVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if shouldShowPreview {
            setPreviewVisible(true)
        } else {
            deferPreviewSuspension()
        }
    }

    func updatePreviewVisibility() {
        setPreviewVisible(shouldShowPreview)
    }

    private var shouldShowPreview: Bool {
        window?.isVisible == true
            && window?.isMiniaturized == false
            && !NSApp.isHidden
            && window?.occlusionState.contains(.visible) == true
    }

    private func deferPreviewSuspension() {
        DispatchQueue.main.async { [weak self] in self?.updatePreviewVisibility() }
    }

    func updatePreviewOverlay(_ frame: PreviewOverlayFrame) {
        guard previewIsVisible else { return }
        previewView.updateHands(frame.hands, sourceAspectRatio: frame.sourceAspectRatio)
    }

    func setCameras(_ choices: [CameraChoice]) {
        cameras = choices
        cameraPopup.removeAllItems()
        for camera in choices {
            cameraPopup.addItem(withTitle: camera.name)
            cameraPopup.lastItem?.representedObject = camera.id
        }

        if choices.contains(where: { $0.id == settings.cameraID }) {
            selectCameraItem(id: settings.cameraID)
        } else if settings.cameraID.isEmpty, !choices.isEmpty {
            cameraPopup.selectItem(at: 0)
            settings.cameraID = choices[0].id
            onSettingsChanged?(settings)
        } else if !settings.cameraID.isEmpty {
            cameraPopup.insertItem(withTitle: "Selected camera unavailable", at: 0)
            cameraPopup.item(at: 0)?.representedObject = settings.cameraID
            cameraPopup.selectItem(at: 0)
        } else {
            cameraPopup.addItem(withTitle: "No cameras found")
        }
        cameraPopup.isEnabled = !choices.isEmpty
    }

    func update(status: TrackerStatus) {
        latestStatus = status
        guard previewIsVisible else { return }
        render(status: status)
    }

    private func render(status: TrackerStatus) {
        stateValue.stringValue = status.state
        cameraValue.stringValue = status.camera
        handsValue.stringValue = "\(status.handCount)"
        fpsValue.stringValue = String(format: "%.1f fps", status.trackingFPS)
        inferenceValue.stringValue = String(format: "%.1f ms", status.inferenceMilliseconds)
        dropsValue.stringValue = "\(status.droppedFrames)"
        oscValue.stringValue = status.oscDestination
        errorLabel.stringValue = status.error
        errorLabel.isHidden = status.error.isEmpty
        startButton.isEnabled = !status.isTracking
        stopButton.isEnabled = status.isTracking
    }

    func showSaveResult(_ message: String, isError: Bool = false) {
        errorLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        controlsChanged(obj.object)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Hand Vision Native")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Apple Vision hand pose to OSC")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        let release = NSTextField(labelWithString: Self.releaseDescription)
        release.textColor = .tertiaryLabelColor
        release.font = .systemFont(ofSize: 11)
        let titleBlock = NSStackView(views: [title, subtitle, release])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 1

        hideButton.target = self
        hideButton.action = #selector(hideWindow(_:))
        hideButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitApplication(_:))
        quitButton.bezelStyle = .rounded
        quitButton.contentTintColor = .systemRed
        let header = horizontal([titleBlock, NSView(), hideButton, quitButton], spacing: 8)

        cameraPopup.target = self
        cameraPopup.action = #selector(controlsChanged(_:))
        cameraPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh cameras")
                ?? NSImage(size: NSSize(width: 16, height: 16)),
            target: self,
            action: #selector(refreshCameras(_:))
        )
        refreshButton.toolTip = "Refresh cameras"
        refreshButton.bezelStyle = .rounded

        startButton.target = self
        startButton.action = #selector(startTracking(_:))
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded
        startButton.contentTintColor = .systemGreen

        stopButton.target = self
        stopButton.action = #selector(stopTracking(_:))
        stopButton.bezelStyle = .rounded
        stopButton.contentTintColor = .systemRed
        stopButton.isEnabled = false

        let cameraRow = horizontal([cameraPopup, refreshButton, startButton, stopButton], spacing: 8)
        cameraPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        configurePopup(presetPopup, values: TrackingPreset.allCases.map(\.rawValue))
        configurePopup(handsPopup, values: ["1", "2"])
        configurePopup(cadencePopup, values: ["10", "15", "20", "30", "40", "60"])
        configurePopup(resolutionPopup, values: CaptureResolution.allCases.map(\.rawValue))
        presetPopup.action = #selector(presetChanged(_:))
        for popup in [handsPopup, cadencePopup, resolutionPopup] {
            popup.action = #selector(controlsChanged(_:))
        }

        zoomSlider.target = self
        zoomSlider.action = #selector(controlsChanged(_:))
        zoomSlider.numberOfTickMarks = 10
        zoomSlider.allowsTickMarkValuesOnly = false
        zoomValueLabel.alignment = .right
        zoomValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        rotationSlider.target = self
        rotationSlider.action = #selector(controlsChanged(_:))
        rotationSlider.isContinuous = true
        rotationField.delegate = self
        rotationField.alignment = .right
        rotationField.toolTip = "Clockwise rotation in degrees"
        rotationField.widthAnchor.constraint(equalToConstant: 58).isActive = true

        hostField.delegate = self
        hostField.toolTip = "OSC destination hostname or IP address"
        portField.delegate = self
        portField.alignment = .right
        portField.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let trackingGrid = NSGridView(views: [
            [fieldLabel("Preset"), presetPopup, fieldLabel("Hands"), handsPopup],
            [fieldLabel("Cadence"), cadencePopup, fieldLabel("Resolution"), resolutionPopup],
            [
                fieldLabel("Zoom"),
                horizontal([zoomSlider, zoomValueLabel], spacing: 6),
                fieldLabel("Rotate"),
                horizontal([rotationSlider, rotationField], spacing: 6)
            ]
        ])
        style(grid: trackingGrid)

        let oscGrid = NSGridView(views: [
            [fieldLabel("Address"), hostField, fieldLabel("Port"), portField]
        ])
        style(grid: oscGrid)

        saveButton.target = self
        saveButton.action = #selector(saveSettings(_:))
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = .systemOrange
        resetButton.target = self
        resetButton.action = #selector(resetSettings(_:))
        resetButton.bezelStyle = .rounded
        resetButton.contentTintColor = .systemTeal
        saveButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        resetButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let actions = horizontal([NSView(), saveButton, resetButton], spacing: 8)

        let statusGrid = NSGridView(views: [
            [fieldLabel("State"), stateValue, fieldLabel("Hands"), handsValue],
            [fieldLabel("Camera"), cameraValue, fieldLabel("Rate"), fpsValue],
            [fieldLabel("Inference"), inferenceValue, fieldLabel("Dropped"), dropsValue],
            [fieldLabel("CPU"), processCPUValue, fieldLabel("RAM"), processRAMValue],
            [fieldLabel("OSC"), oscValue, NSView(), NSView()]
        ])
        style(grid: statusGrid)
        for value in [handsValue, fpsValue, inferenceValue, dropsValue, processCPUValue, processRAMValue] {
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let root = NSStackView(views: [
            header,
            previewView,
            separator(),
            sectionTitle("Camera"),
            cameraRow,
            sectionTitle("Tracking"),
            trackingGrid,
            sectionTitle("Output"),
            oscGrid,
            actions,
            separator(),
            sectionTitle("Live"),
            statusGrid,
            errorLabel
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            previewView.widthAnchor.constraint(equalTo: root.widthAnchor),
            previewView.heightAnchor.constraint(equalToConstant: 230),
            cameraRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            trackingGrid.widthAnchor.constraint(equalTo: root.widthAnchor),
            oscGrid.widthAnchor.constraint(equalTo: root.widthAnchor),
            actions.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusGrid.widthAnchor.constraint(equalTo: root.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func configurePopup(_ popup: NSPopUpButton, values: [String]) {
        popup.addItems(withTitles: values)
        popup.target = self
    }

    private static var releaseDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let date = Bundle.main.object(forInfoDictionaryKey: "PoseDtxReleaseDate") as? String
            ?? "unreleased"
        return "Version \(version)  •  Released \(date)"
    }

    private func setPreviewVisible(_ visible: Bool) {
        guard previewIsVisible != visible else { return }
        previewIsVisible = visible
        if visible {
            previewView.attach()
            render(status: latestStatus)
            processCPUValue.stringValue = "Sampling…"
            processRAMValue.stringValue = "Sampling…"
            metricsSampler.start { [weak self] cpuPercent, residentMegabytes in
                self?.processCPUValue.stringValue = String(format: "%.1f%%", cpuPercent)
                self?.processRAMValue.stringValue = String(format: "%.1f MB", residentMegabytes)
            }
            onPreviewVisibilityChanged?(true)
        } else {
            onPreviewVisibilityChanged?(false)
            previewView.detach()
            metricsSampler.stop()
            processCPUValue.stringValue = "Paused"
            processRAMValue.stringValue = "Paused"
        }
    }

    private func applySettingsToControls() {
        presetPopup.selectItem(withTitle: settings.preset.rawValue)
        handsPopup.selectItem(withTitle: "\(settings.maxHands)")
        cadencePopup.selectItem(withTitle: String(format: "%.0f", settings.cadenceHz))
        resolutionPopup.selectItem(withTitle: settings.resolution.rawValue)
        zoomSlider.doubleValue = settings.zoom
        zoomValueLabel.stringValue = String(format: "%.2fx", settings.zoom)
        rotationSlider.doubleValue = settings.rotation
        rotationField.stringValue = String(format: "%.2f", settings.rotation)
        hostField.stringValue = settings.oscHost
        portField.integerValue = settings.oscPort
        oscValue.stringValue = "\(settings.oscHost):\(settings.oscPort)"
        previewView.update(
            rotation: settings.rotation,
            zoom: settings.zoom,
            resolution: settings.resolution
        )

        selectCameraItem(id: settings.cameraID)
    }

    @discardableResult
    private func selectCameraItem(id: String) -> Bool {
        guard !id.isEmpty,
              let item = cameraPopup.itemArray.first(where: {
                  ($0.representedObject as? String) == id
              }) else { return false }
        cameraPopup.select(item)
        return true
    }

    @objc private func controlsChanged(_ sender: Any?) {
        if let cameraID = cameraPopup.selectedItem?.representedObject as? String {
            settings.cameraID = cameraID
        }
        settings.maxHands = handsPopup.titleOfSelectedItem.flatMap(Int.init) ?? settings.maxHands
        settings.cadenceHz = cadencePopup.titleOfSelectedItem.flatMap(Double.init) ?? settings.cadenceHz
        if let title = resolutionPopup.titleOfSelectedItem,
           let resolution = CaptureResolution(rawValue: title) {
            settings.resolution = resolution
        }
        settings.zoom = zoomSlider.doubleValue
        if let slider = sender as? NSSlider, slider === rotationSlider {
            settings.rotation = rotationSlider.doubleValue
        } else {
            settings.rotation = rotationField.doubleValue
        }
        settings.oscHost = hostField.stringValue
        settings.oscPort = portField.integerValue
        settings.sanitize()
        settings.updatePresetFromTuning()
        applySettingsToControls()
        onSettingsChanged?(settings)
    }

    @objc private func presetChanged(_ sender: Any?) {
        guard let title = presetPopup.titleOfSelectedItem,
              let preset = TrackingPreset(rawValue: title) else { return }
        settings.applyPreset(preset)
        applySettingsToControls()
        onSettingsChanged?(settings)
    }

    @objc private func refreshCameras(_ sender: Any?) {
        onRefreshCameras?()
    }

    @objc private func startTracking(_ sender: Any?) {
        controlsChanged(nil)
        onStart?()
    }

    @objc private func stopTracking(_ sender: Any?) {
        onStop?()
    }

    @objc private func hideWindow(_ sender: Any?) {
        onHide?()
    }

    @objc private func quitApplication(_ sender: Any?) {
        onQuit?()
    }

    @objc private func saveSettings(_ sender: Any?) {
        controlsChanged(nil)
        do {
            try onSave?(settings)
            showSaveResult("Settings saved.")
        } catch {
            showSaveResult("Could not save settings: \(error.localizedDescription)", isError: true)
        }
    }

    @objc private func resetSettings(_ sender: Any?) {
        guard let reset = onReset else { return }
        settings = reset()
        applySettingsToControls()
        onSettingsChanged?(settings)
        showSaveResult("Saved settings cleared.")
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func style(grid: NSGridView) {
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        if grid.numberOfColumns >= 4 {
            grid.column(at: 0).width = 72
            grid.column(at: 2).width = 72
        }
    }
}
