import AppKit
import AVFoundation
import MoveoTrackerCore

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
    private let modeControl = NSSegmentedControl(
        labels: TrackingMode.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let presetPopup = NSPopUpButton()
    private let subjectsControl = NSSegmentedControl(
        labels: ["1", "2", "Unlimited"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let cadencePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let zoomField = NSTextField(string: "1.00")
    private let rotationSlider = NSSlider(value: 0, minValue: 0, maxValue: 359.99, target: nil, action: nil)
    private let rotationField = NSTextField(string: "0")
    private let hostField = NSTextField(string: "127.0.0.1")
    private let portField = NSTextField(string: "9000")
    private let trackingButton = NSButton(title: "Start Tracking", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let hideButton = NSButton(title: "Hide", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let statusDot = NSView()

    private let stateValue = NSTextField(labelWithString: "Idle")
    private let cameraValue = NSTextField(labelWithString: "None")
    private let detectionsValue = NSTextField(labelWithString: "0")
    private let fpsValue = NSTextField(labelWithString: "0.0 fps")
    private let inferenceValue = NSTextField(labelWithString: "0.0 ms")
    private let dropsValue = NSTextField(labelWithString: "0")
    private let oscValue = NSTextField(labelWithString: "127.0.0.1:9000")
    private let oscAddressesValue = NSTextField(labelWithString: "")
    private let processCPUValue = NSTextField(labelWithString: "Paused")
    private let processRAMValue = NSTextField(labelWithString: "Paused")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let unlimitedHintLabel = NSTextField(
        labelWithString: "Unlimited tracks every result and may use much more CPU."
    )
    private let previewView: CameraPreviewView
    private var previewAspectConstraint: NSLayoutConstraint?
    private var previewAspectRatio: CGFloat = 4 / 3
    private let metricsSampler = ProcessMetricsSampler()

    init(settings: AppSettings, previewSession: AVCaptureSession) {
        self.settings = settings
        self.previewView = CameraPreviewView(session: previewSession)
        self.previewAspectRatio = settings.resolution.aspectRatio
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Moveo Tracker"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 900, height: 500)
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
        updatePreviewAspectRatio(frame.sourceAspectRatio)
        previewView.updateProcessedFrame(frame.image)
        previewView.updateDetections(frame.detections, sourceAspectRatio: frame.sourceAspectRatio)
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
        stateValue.textColor = !status.error.isEmpty
            ? .systemRed
            : (status.isTracking ? .systemGreen : .secondaryLabelColor)
        statusDot.layer?.backgroundColor = (!status.error.isEmpty
            ? NSColor.systemRed
            : (status.isTracking ? NSColor.systemGreen : NSColor.tertiaryLabelColor)).cgColor
        cameraValue.stringValue = status.camera
        detectionsValue.stringValue = "\(status.detectionCount) \(settings.trackingMode.subjectLabel)"
        fpsValue.stringValue = String(format: "%.1f fps", status.trackingFPS)
        inferenceValue.stringValue = String(format: "%.1f ms", status.inferenceMilliseconds)
        dropsValue.stringValue = "\(status.droppedFrames)"
        oscValue.stringValue = status.oscDestination
        errorLabel.stringValue = status.error
        errorLabel.isHidden = status.error.isEmpty
        trackingButton.title = status.isTracking ? "Stop Tracking" : "Start Tracking"
        trackingButton.bezelColor = status.isTracking ? .systemRed : .controlAccentColor
        trackingButton.contentTintColor = .white
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
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Moveo Tracker")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Apple Vision tracking to OSC")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 10.5)
        let titleBlock = NSStackView(views: [title, subtitle])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 1

        hideButton.target = self
        hideButton.action = #selector(hideWindow(_:))
        hideButton.bezelStyle = .rounded
        hideButton.controlSize = .small
        quitButton.target = self
        quitButton.action = #selector(quitApplication(_:))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.contentTintColor = .systemRed
        let header = horizontal([
            appMark(),
            titleBlock,
            NSView(),
            hideButton,
            quitButton
        ], spacing: 7)

        cameraPopup.target = self
        cameraPopup.action = #selector(controlsChanged(_:))
        cameraPopup.controlSize = .regular
        cameraPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh cameras")
                ?? NSImage(size: NSSize(width: 16, height: 16)),
            target: self,
            action: #selector(refreshCameras(_:))
        )
        refreshButton.toolTip = "Refresh cameras"
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .regular
        refreshButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        trackingButton.target = self
        trackingButton.action = #selector(toggleTracking(_:))
        trackingButton.bezelStyle = .rounded
        trackingButton.controlSize = .large
        trackingButton.font = .systemFont(ofSize: 13, weight: .semibold)
        trackingButton.bezelColor = .controlAccentColor
        trackingButton.contentTintColor = .white
        trackingButton.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let cameraRow = horizontal([cameraPopup, refreshButton], spacing: 6)

        configurePopup(presetPopup, values: TrackingPreset.allCases.map(\.rawValue))
        configurePopup(cadencePopup, values: ["10", "15", "20", "30", "40", "60"])
        configurePopup(resolutionPopup, values: CaptureResolution.allCases.map(\.displayName))
        modeControl.target = self
        modeControl.action = #selector(controlsChanged(_:))
        modeControl.controlSize = .regular
        modeControl.segmentStyle = .rounded
        modeControl.setWidth(92, forSegment: 0)
        modeControl.setWidth(92, forSegment: 1)
        modeControl.setWidth(92, forSegment: 2)
        subjectsControl.target = self
        subjectsControl.action = #selector(controlsChanged(_:))
        subjectsControl.controlSize = .regular
        subjectsControl.segmentStyle = .rounded
        subjectsControl.setWidth(38, forSegment: 0)
        subjectsControl.setWidth(38, forSegment: 1)
        subjectsControl.setWidth(76, forSegment: 2)
        presetPopup.action = #selector(presetChanged(_:))
        for popup in [cadencePopup, resolutionPopup] {
            popup.action = #selector(controlsChanged(_:))
        }

        zoomSlider.target = self
        zoomSlider.action = #selector(controlsChanged(_:))
        zoomSlider.numberOfTickMarks = 10
        zoomSlider.allowsTickMarkValuesOnly = false
        zoomSlider.controlSize = .small
        zoomField.delegate = self
        zoomField.alignment = .right
        zoomField.controlSize = .small
        zoomField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        zoomField.placeholderString = "1.00"
        zoomField.toolTip = "Type an exact zoom from 1 to 10"
        zoomField.setAccessibilityLabel("Zoom multiplier")
        zoomField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        rotationSlider.target = self
        rotationSlider.action = #selector(controlsChanged(_:))
        rotationSlider.isContinuous = true
        rotationSlider.controlSize = .small
        rotationField.delegate = self
        rotationField.alignment = .right
        rotationField.controlSize = .small
        rotationField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        rotationField.placeholderString = "0"
        rotationField.toolTip = "Type an exact clockwise rotation in degrees"
        rotationField.setAccessibilityLabel("Rotation degrees")
        rotationField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        hostField.delegate = self
        hostField.toolTip = "OSC destination hostname or IP address"
        hostField.controlSize = .small
        portField.delegate = self
        portField.alignment = .right
        portField.controlSize = .small
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        unlimitedHintLabel.font = .systemFont(ofSize: 10, weight: .medium)
        unlimitedHintLabel.textColor = .systemOrange
        unlimitedHintLabel.isHidden = true

        let presetColumn = controlColumn("Performance", presetPopup)
        let maximumColumn = controlColumn("Maximum", subjectsControl)
        presetColumn.widthAnchor.constraint(equalToConstant: 138).isActive = true
        maximumColumn.widthAnchor.constraint(equalToConstant: 198).isActive = true
        let tuningRow = horizontal([presetColumn, maximumColumn], spacing: 8)
        let rateColumn = controlColumn("Rate (fps)", cadencePopup)
        let qualityColumn = controlColumn("Quality", resolutionPopup)
        rateColumn.widthAnchor.constraint(equalToConstant: 138).isActive = true
        qualityColumn.widthAnchor.constraint(equalToConstant: 198).isActive = true
        let performanceRow = horizontal([rateColumn, qualityColumn], spacing: 8)
        let zoomRow = parameterRow("Zoom (×)", value: zoomField, control: zoomSlider)
        let rotateRow = parameterRow("Rotation (°)", value: rotationField, control: rotationSlider)
        let trackingContent = vertical([
            tuningRow,
            performanceRow,
            zoomRow,
            rotateRow,
            unlimitedHintLabel
        ], spacing: 5)

        saveButton.target = self
        saveButton.action = #selector(saveSettings(_:))
        saveButton.title = "Save settings"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetSettings(_:))
        resetButton.title = "Reset"
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        let addressColumn = controlColumn("Host", hostField)
        let portColumn = controlColumn("Port", portField)
        addressColumn.widthAnchor.constraint(equalToConstant: 232).isActive = true
        portColumn.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let outputFields = horizontal([addressColumn, portColumn], spacing: 8)
        let actions = horizontal([saveButton, resetButton, NSView()], spacing: 6)
        let outputContent = vertical([outputFields, actions], spacing: 5)

        for value in [detectionsValue, fpsValue, inferenceValue, dropsValue, processCPUValue, processRAMValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let metricRow = horizontal([
            metric("Found", value: detectionsValue),
            metric("Rate", value: fpsValue),
            metric("Latency", value: inferenceValue)
        ], spacing: 6)
        let resourceRow = horizontal([
            compactStat("CPU", value: processCPUValue),
            compactStat("RAM", value: processRAMValue),
            compactStat("Dropped", value: dropsValue)
        ], spacing: 10)
        cameraValue.font = .systemFont(ofSize: 10.5)
        cameraValue.textColor = .secondaryLabelColor
        oscValue.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        oscAddressesValue.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        oscAddressesValue.textColor = .secondaryLabelColor
        oscAddressesValue.lineBreakMode = .byTruncatingMiddle
        let destination = destinationSummary()
        destination.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let liveMainRow = horizontal([metricRow, destination], spacing: 8)
        let liveContent = vertical([resourceRow, liveMainRow], spacing: 6)
        liveMainRow.widthAnchor.constraint(equalTo: liveContent.widthAnchor).isActive = true
        let livePanel = section(title: "Live", content: liveContent)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.isHidden = true

        let creditButton = NSButton(
            title: "Made by @jpjullin  ·  GitHub",
            target: self,
            action: #selector(openGitHub(_:))
        )
        creditButton.isBordered = false
        creditButton.font = .systemFont(ofSize: 10)
        creditButton.contentTintColor = .secondaryLabelColor
        creditButton.toolTip = "Open github.com/jpjullin/moveo-tracker"
        let release = NSTextField(labelWithString: Self.releaseDescription)
        release.textColor = .tertiaryLabelColor
        release.font = .systemFont(ofSize: 9.5)
        let footer = horizontal([creditButton, NSView(), release], spacing: 6)

        let sidebarStack = NSStackView(views: [
            header,
            section(title: "Camera", content: cameraRow),
            section(title: "Model", content: modeControl),
            section(title: "Tracking", content: trackingContent),
            section(title: "Output", content: outputContent),
            footer
        ])
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .width
        sidebarStack.distribution = .equalSpacing
        sidebarStack.spacing = 16
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        let workspaceHeader = horizontal([statusChip(), NSView(), trackingButton], spacing: 10)
        let previewContainer = NSView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewView)
        previewAspectConstraint = previewView.widthAnchor.constraint(
            equalTo: previewView.heightAnchor,
            multiplier: previewAspectRatio
        )
        previewAspectConstraint?.isActive = true
        let fillPreviewWidth = previewView.widthAnchor.constraint(equalTo: previewContainer.widthAnchor)
        fillPreviewWidth.priority = .init(750)
        let fillPreviewHeight = previewView.heightAnchor.constraint(equalTo: previewContainer.heightAnchor)
        fillPreviewHeight.priority = .init(749)
        NSLayoutConstraint.activate([
            previewView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            previewView.leadingAnchor.constraint(greaterThanOrEqualTo: previewContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor),
            previewView.topAnchor.constraint(greaterThanOrEqualTo: previewContainer.topAnchor),
            previewView.bottomAnchor.constraint(lessThanOrEqualTo: previewContainer.bottomAnchor),
            fillPreviewWidth,
            fillPreviewHeight
        ])
        let workspace = vertical([workspaceHeader, previewContainer, livePanel, errorLabel], spacing: 10)
        workspace.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(sidebar)
        contentView.addSubview(workspace)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 380),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 38),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),

            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            workspace.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            workspace.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 38),
            workspace.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            header.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            cameraRow.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            modeControl.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            tuningRow.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            performanceRow.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            zoomRow.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            rotateRow.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            outputFields.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            workspaceHeader.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            previewContainer.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            metricRow.widthAnchor.constraint(equalToConstant: 342),
            livePanel.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: workspace.widthAnchor)
        ])
    }

    private func configurePopup(_ popup: NSPopUpButton, values: [String]) {
        popup.addItems(withTitles: values)
        popup.target = self
    }

    private static var releaseDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let date = Bundle.main.object(forInfoDictionaryKey: "MoveoTrackerReleaseDate") as? String
            ?? "unreleased"
        return "v\(version) · \(date)"
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
        modeControl.selectedSegment = TrackingMode.allCases.firstIndex(of: settings.trackingMode) ?? 0
        presetPopup.selectItem(withTitle: settings.preset.rawValue)
        subjectsControl.selectedSegment = settings.isUnlimited ? 2 : max(0, settings.maxHands - 1)
        unlimitedHintLabel.isHidden = !settings.isUnlimited
        cadencePopup.selectItem(withTitle: String(format: "%.0f", settings.cadenceHz))
        resolutionPopup.selectItem(withTitle: settings.resolution.displayName)
        zoomSlider.doubleValue = settings.zoom
        zoomField.stringValue = String(format: "%.2f", settings.zoom)
        rotationSlider.doubleValue = settings.rotation
        rotationField.stringValue = String(format: "%.2f", settings.rotation)
        hostField.stringValue = settings.oscHost
        portField.stringValue = "\(settings.oscPort)"
        oscValue.stringValue = "\(settings.oscHost):\(settings.oscPort)"
        updateOSCAddresses()
        previewView.update(
            rotation: settings.rotation,
            zoom: settings.zoom,
            resolution: settings.resolution
        )
        updatePreviewAspectRatio()

        selectCameraItem(id: settings.cameraID)
    }

    private func updatePreviewAspectRatio(_ sourceAspectRatio: CGFloat? = nil) {
        let desiredRatio = sourceAspectRatio
            ?? settings.resolution.aspectRatio
        guard desiredRatio.isFinite, desiredRatio > 0 else { return }
        guard previewAspectConstraint != nil else {
            previewAspectRatio = desiredRatio
            return
        }
        guard abs(desiredRatio - previewAspectRatio) > 0.000_1 else { return }
        previewAspectRatio = desiredRatio
        previewAspectConstraint?.isActive = false
        previewAspectConstraint = previewView.widthAnchor.constraint(
            equalTo: previewView.heightAnchor,
            multiplier: previewAspectRatio
        )
        previewAspectConstraint?.isActive = true
    }

    private func updateOSCAddresses() {
        let slots = settings.isUnlimited ? "{0…}" : (settings.maxHands == 1 ? "0" : "{0,1}")
        let addresses: String
        switch settings.trackingMode {
        case .hands:
            addresses = "/hand/\(slots)/landmarks   /hand/\(slots)/meta   /hands/active"
        case .body:
            addresses = "/body/\(slots)/landmarks   /body/\(slots)/meta   /bodies/active"
        case .face:
            addresses = "/face/\(slots)/landmarks   /face/\(slots)/bounds   /faces/active"
        }
        oscAddressesValue.stringValue = addresses
        oscAddressesValue.toolTip = addresses
        oscAddressesValue.lineBreakMode = .byTruncatingTail
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
        if let slider = sender as? NSSlider, slider === rotationSlider {
            settings.rotation = rotationSlider.doubleValue
            settings.sanitize()
            rotationField.stringValue = String(format: "%.2f", settings.rotation)
            previewView.update(
                rotation: settings.rotation,
                zoom: settings.zoom,
                resolution: settings.resolution
            )
            onSettingsChanged?(settings)
            return
        }
        if let slider = sender as? NSSlider, slider === zoomSlider {
            settings.zoom = zoomSlider.doubleValue
            settings.sanitize()
            zoomField.stringValue = String(format: "%.2f", settings.zoom)
            previewView.update(
                rotation: settings.rotation,
                zoom: settings.zoom,
                resolution: settings.resolution
            )
            onSettingsChanged?(settings)
            return
        }

        if modeControl.selectedSegment >= 0,
           let title = modeControl.label(forSegment: modeControl.selectedSegment),
           let mode = TrackingMode(rawValue: title) {
            settings.trackingMode = mode
        }
        if let cameraID = cameraPopup.selectedItem?.representedObject as? String {
            settings.cameraID = cameraID
        }
        if subjectsControl.selectedSegment == 2 {
            settings.maxHands = AppSettings.unlimited
        } else {
            settings.maxHands = max(1, subjectsControl.selectedSegment + 1)
        }
        settings.cadenceHz = cadencePopup.titleOfSelectedItem.flatMap(Double.init) ?? settings.cadenceHz
        if let title = resolutionPopup.titleOfSelectedItem,
           let resolution = CaptureResolution.allCases.first(where: { $0.displayName == title }) {
            settings.resolution = resolution
        }
        if let field = sender as? NSTextField, field === zoomField {
            settings.zoom = zoomField.doubleValue
        } else {
            settings.zoom = zoomSlider.doubleValue
        }
        settings.rotation = rotationField.doubleValue
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

    @objc private func toggleTracking(_ sender: Any?) {
        if latestStatus.isTracking {
            onStop?()
        } else {
            controlsChanged(nil)
            onStart?()
        }
    }

    @objc private func hideWindow(_ sender: Any?) {
        onHide?()
    }

    @objc private func quitApplication(_ sender: Any?) {
        onQuit?()
    }

    @objc private func openGitHub(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/jpjullin/moveo-tracker") else { return }
        NSWorkspace.shared.open(url)
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

    private func appMark() -> NSView {
        let mark = NSView()
        mark.wantsLayer = true
        mark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        mark.layer?.cornerRadius = 9

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: "Moveo Tracker"
        ) ?? NSImage(size: NSSize(width: 16, height: 16)))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(icon)

        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 32),
            mark.heightAnchor.constraint(equalToConstant: 32),
            icon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: mark.centerYAnchor)
        ])
        return mark
    }

    private func section(title: String, content: NSView) -> NSView {
        let symbolName: String
        switch title {
        case "Camera": symbolName = "video.fill"
        case "Model": symbolName = "viewfinder"
        case "Tracking": symbolName = "slider.horizontal.3"
        case "Output": symbolName = "dot.radiowaves.left.and.right"
        default: symbolName = "waveform.path.ecg"
        }
        let icon = NSImageView(image: NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) ?? NSImage(size: NSSize(width: 12, height: 12)))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .labelColor
        let titleRow = horizontal([icon, heading, NSView()], spacing: 5)
        let stack = vertical([titleRow, content], spacing: 5)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func controlColumn(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        let stack = vertical([label, control], spacing: 2)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func parameterRow(_ title: String, value: NSView, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        let titleRow = horizontal([label, NSView(), value], spacing: 4)
        let stack = vertical([titleRow, control], spacing: 0)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func metric(_ title: String, value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let stack = vertical([label, value], spacing: 1)
        return surface(stack, horizontal: 8, vertical: 5, width: 110)
    }

    private func compactStat(_ title: String, value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5)
        label.textColor = .tertiaryLabelColor
        value.lineBreakMode = .byTruncatingMiddle
        return horizontal([label, value], spacing: 4)
    }

    private func destinationSummary() -> NSView {
        let sending = NSTextField(labelWithString: "SENDING TO")
        sending.font = .systemFont(ofSize: 8.5, weight: .semibold)
        sending.textColor = .tertiaryLabelColor
        let stack = vertical([
            compactStat("Camera", value: cameraValue),
            sending,
            oscValue,
            oscAddressesValue
        ], spacing: 1)
        return surface(stack, horizontal: 8, vertical: 5)
    }

    private func statusChip() -> NSView {
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        statusDot.layer?.cornerRadius = 3.5
        statusDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        stateValue.font = .systemFont(ofSize: 11, weight: .medium)

        let row = horizontal([statusDot, stateValue], spacing: 6)
        return surface(row, horizontal: 9, vertical: 5)
    }

    private func surface(
        _ content: NSView,
        horizontal: CGFloat,
        vertical: CGFloat,
        width: CGFloat? = nil
    ) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        view.layer?.cornerRadius = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        var constraints = [
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -vertical)
        ]
        if let width {
            constraints.append(view.widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        return view
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

}
