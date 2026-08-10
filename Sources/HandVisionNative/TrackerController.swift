import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import HandVisionCore
import ImageIO
import Vision

struct CameraChoice: Equatable {
    var id: String
    var name: String
}

struct TrackerStatus: Equatable {
    var state: String = "Idle"
    var camera: String = "None"
    var handCount: Int = 0
    var trackingFPS: Double = 0
    var inferenceMilliseconds: Double = 0
    var droppedFrames: Int = 0
    var oscDestination: String = "127.0.0.1:9000"
    var error: String = ""
    var isTracking: Bool = false
}

struct PreviewOverlayFrame: Sendable {
    var hands: [[NormalizedLandmark]]
    var sourceAspectRatio: CGFloat
}

private struct TrackingHeartbeatSnapshot: Sendable {
    var appRunning = true
    var trackingActive = false
    var handCount = 0
    var trackingFPS = 0.0
}

final class TrackerController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onStatus: ((TrackerStatus) -> Void)?
    var onCameras: (([CameraChoice]) -> Void)?
    var onPreviewOverlay: ((PreviewOverlayFrame) -> Void)?
    var previewSession: AVCaptureSession { session }

    private let inferenceQueue = DispatchQueue(
        label: "site.posedtx.hand-vision-native.inference",
        qos: .userInitiated
    )
    private let heartbeatQueue = DispatchQueue(
        label: "site.posedtx.hand-vision-native.heartbeat",
        qos: .utility
    )
    private let session = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private let request = VNDetectHumanHandPoseRequest()
    private let osc = OSCSender()
    private let metaCalculator = HandMetaCalculator()
    private var frameCadence = FrameCadence()
    private var trackingIntent = TrackingIntent()
    private var captureWatchdog = CaptureWatchdog()
    private var lossHysteresis = HandLossHysteresis()

    private var settings: AppSettings
    private var status: TrackerStatus
    private var heartbeatTimer: DispatchSourceTimer?
    private var fpsWindowStarted = ProcessInfo.processInfo.systemUptime
    private var fpsWindowFrames = 0
    private var lastStatusPublish = -Double.infinity
    private var currentInput: AVCaptureDeviceInput?
    private var captureObservers: [NSObjectProtocol] = []
    private var resumeWhenCameraReturns = false
    private var waitingCameraID: String?
    private var trackingActivity: NSObjectProtocol?
    private var captureInterrupted = false
    private var trackingError = ""
    private var oscError = ""
    private let previewPublishingLock = NSLock()
    private var previewPublishingEnabled = false
    private var pendingPreviewFrame: PreviewOverlayFrame?
    private var previewDeliveryScheduled = false
    private let statusPublishingLock = NSLock()
    private var pendingPublishedStatus: TrackerStatus?
    private var statusDeliveryScheduled = false
    private let heartbeatLock = NSLock()
    private var heartbeatSnapshot = TrackingHeartbeatSnapshot()
    private let cameraPermissionLock = NSLock()
    private var cameraPermissionRequestID: UInt64 = 0
    private var lastPreviewAspectRatio: CGFloat = 4 / 3
    private var shuttingDown = false

    init(settings: AppSettings) {
        var clean = settings
        clean.sanitize()
        self.settings = clean
        self.status = TrackerStatus(oscDestination: "\(clean.oscHost):\(clean.oscPort)")
        super.init()

        request.maximumHandCount = clean.maxHands
        osc.configure(host: clean.oscHost, port: clean.oscPort)
        osc.onError = { [weak self] message in
            self?.inferenceQueue.async { [weak self] in
                guard let self else { return }
                self.oscError = message
                self.refreshStatusError()
                self.publishStatus()
            }
        }
        installCaptureObservers()
        updateHeartbeatSnapshot()
        installHeartbeatTimer()
    }

    func refreshCameras() {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let cameras = self.discoverCameras().map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
            DispatchQueue.main.async { [weak self] in self?.onCameras?(cameras) }
        }
    }

    func updateSettings(_ updated: AppSettings) {
        var clean = updated
        clean.sanitize()
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let cadenceChanged = self.settings.cadenceHz != clean.cadenceHz
            let needsRestart = self.trackingIntent.shouldRunCapture && (
                self.settings.cameraID != clean.cameraID ||
                self.settings.resolution != clean.resolution
            )
            self.settings = clean
            self.request.maximumHandCount = clean.maxHands
            self.status.oscDestination = "\(clean.oscHost):\(clean.oscPort)"
            self.osc.configure(host: clean.oscHost, port: clean.oscPort)

            if needsRestart {
                self.rebuildCaptureSession(state: "Starting", message: "Applying camera settings.")
            } else {
                if cadenceChanged, self.trackingIntent.shouldRunCapture {
                    self.frameCadence.reset()
                }
                self.publishStatus()
            }
        }
    }

    func start() {
        let permissionRequestID = beginCameraPermissionRequest()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            inferenceQueue.async { [weak self] in
                guard let self,
                      self.isCurrentCameraPermissionRequest(permissionRequestID) else { return }
                self.requestTrackingStart()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.inferenceQueue.async {
                    guard self.isCurrentCameraPermissionRequest(permissionRequestID) else { return }
                    if granted {
                        self.requestTrackingStart()
                    } else {
                        self.fail("Camera permission was denied. Enable it in System Settings > Privacy & Security > Camera.")
                    }
                }
            }
        case .denied, .restricted:
            inferenceQueue.async { [weak self] in
                self?.fail("Camera access is unavailable. Check System Settings > Privacy & Security > Camera.")
            }
        @unknown default:
            inferenceQueue.async { [weak self] in self?.fail("Unknown camera authorization state.") }
        }
    }

    func stop() {
        invalidateCameraPermissionRequests()
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            self.trackingIntent.requestStop()
            self.resumeWhenCameraReturns = false
            self.waitingCameraID = nil
            self.endTrackingActivity()
            self.stopCapture(sendStatus: true)
        }
    }

    func setPreviewPublishingEnabled(_ enabled: Bool) {
        previewPublishingLock.lock()
        previewPublishingEnabled = enabled
        if !enabled { pendingPreviewFrame = nil }
        previewPublishingLock.unlock()
    }

    func systemWillSleep() {
        inferenceQueue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.trackingIntent.systemWillSleep()
            guard self.trackingIntent.isRequested else { return }
            self.tearDownCapturePipeline()
            self.captureWatchdog.stop()
            self.lossHysteresis.reset()
            self.metaCalculator.reset()
            self.endTrackingActivity()
            self.status.state = "Sleeping"
            self.status.isTracking = true
            self.status.handCount = 0
            self.status.trackingFPS = 0
            self.clearPreviewOverlay()
            self.sendActiveHands([0, 0])
            self.publishStatus()
            self.sendTrackingStatus(appRunning: true)
        }
    }

    func systemDidWake() {
        inferenceQueue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.publishCameras()
            self.trackingIntent.systemDidWake()
            guard self.trackingIntent.shouldRunCapture else { return }
            self.startCapture(state: "Resuming", message: "Waiting for camera frames after wake.")
        }
    }

    func shutdown() {
        invalidateCameraPermissionRequests()
        heartbeatQueue.sync {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
        inferenceQueue.sync {
            shuttingDown = true
            trackingIntent.requestStop()
            endTrackingActivity()
            captureObservers.forEach(NotificationCenter.default.removeObserver)
            captureObservers.removeAll()
            stopCapture(sendStatus: false)
            updateHeartbeatSnapshot(appRunning: false)
            osc.sendAndWait(
                address: "/tracking/status",
                arguments: OSCContract.trackingStatusArguments(
                    appRunning: false,
                    trackingActive: false,
                    handCount: 0,
                    trackingFPS: 0
                )
            )
        }
        osc.shutdown()
    }

    private func installHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendHeartbeatSnapshot()
            self.inferenceQueue.async { [weak self] in
                self?.checkCaptureHealth()
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func installCaptureObservers() {
        let center = NotificationCenter.default
        captureObservers.append(center.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.video) else { return }
            self?.inferenceQueue.async { [weak self] in
                guard let self, !self.shuttingDown else { return }
                self.publishCameras()
                guard self.resumeWhenCameraReturns,
                      self.trackingIntent.shouldRunCapture else { return }
                if let waitingCameraID = self.waitingCameraID,
                   device.uniqueID != waitingCameraID { return }
                self.resumeWhenCameraReturns = false
                self.waitingCameraID = nil
                self.startCapture(state: "Resuming", message: "Waiting for frames from the reconnected camera.")
            }
        })
        captureObservers.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.video) else { return }
            self?.inferenceQueue.async { [weak self] in
                guard let self, !self.shuttingDown else { return }
                self.publishCameras()
                guard self.currentInput?.device.uniqueID == device.uniqueID else { return }
                guard self.trackingIntent.isRequested || self.session.isRunning else { return }
                self.resumeWhenCameraReturns = self.trackingIntent.isRequested
                self.waitingCameraID = device.uniqueID
                self.tearDownCapturePipeline()
                self.captureWatchdog.stop()
                self.lossHysteresis.reset()
                self.metaCalculator.reset()
                self.endTrackingActivity()
                self.status.state = "Waiting for camera"
                self.status.isTracking = self.trackingIntent.isRequested
                self.status.handCount = 0
                self.status.trackingFPS = 0
                self.setTrackingError("The selected camera was disconnected. Tracking will resume if it reconnects.")
                self.clearPreviewOverlay()
                self.sendActiveHands([0, 0])
                self.publishStatus()
                self.sendTrackingStatus(appRunning: true)
            }
        })
        captureObservers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.inferenceQueue.async { [weak self] in
                self?.handleRuntimeError(notification)
            }
        })
        captureObservers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.inferenceQueue.async { [weak self] in
                guard let self,
                      self.trackingIntent.isRequested,
                      !self.shuttingDown,
                      self.currentInput != nil,
                      self.videoOutput != nil,
                      !self.resumeWhenCameraReturns else { return }
                self.captureInterrupted = true
                self.captureWatchdog.captureStarted(at: ProcessInfo.processInfo.systemUptime)
                self.status.state = "Interrupted"
                self.status.handCount = 0
                self.status.trackingFPS = 0
                self.setTrackingError("Camera capture was interrupted.")
                self.lossHysteresis.reset()
                self.metaCalculator.reset()
                self.clearPreviewOverlay()
                self.sendActiveHands([0, 0])
                self.publishStatus()
                self.sendTrackingStatus(appRunning: true)
            }
        })
        captureObservers.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.inferenceQueue.async { [weak self] in
                guard let self else { return }
                guard self.captureInterrupted,
                      self.currentInput != nil,
                      self.videoOutput != nil,
                      !self.resumeWhenCameraReturns else { return }
                self.captureInterrupted = false
                self.resumeAfterInterruption()
            }
        })
    }

    private func publishCameras() {
        let cameras = discoverCameras().map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        DispatchQueue.main.async { [weak self] in self?.onCameras?(cameras) }
    }

    private func handleRuntimeError(_ notification: Notification) {
        guard !shuttingDown,
              trackingIntent.shouldRunCapture,
              currentInput != nil,
              videoOutput != nil,
              !resumeWhenCameraReturns else { return }
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let now = ProcessInfo.processInfo.systemUptime
        guard captureWatchdog.canAttemptRecovery(at: now) else { return }
        captureWatchdog.recordRecoveryAttempt(at: now)
        let description = "Camera runtime error; rebuilding capture: " +
            (error?.localizedDescription ?? "Unknown AVFoundation error")
        rebuildCaptureSession(state: "Recovering", message: description)
    }

    private func resumeAfterInterruption() {
        guard !shuttingDown, trackingIntent.shouldRunCapture else { return }
        if !session.isRunning { session.startRunning() }
        captureWatchdog.captureStarted(at: ProcessInfo.processInfo.systemUptime)
        status.state = "Resuming"
        status.handCount = 0
        status.trackingFPS = 0
        setTrackingError("Waiting for camera frames after interruption.")
        publishStatus()
        sendTrackingStatus(appRunning: true)
    }

    private func discoverCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func selectedCamera() -> AVCaptureDevice? {
        let cameras = discoverCameras()
        if !settings.cameraID.isEmpty {
            return cameras.first(where: { $0.uniqueID == settings.cameraID })
        }
        return cameras.first
    }

    private func requestTrackingStart() {
        guard !shuttingDown else { return }
        if trackingIntent.shouldRunCapture,
           currentInput != nil || session.isRunning {
            return
        }
        trackingIntent.requestStart()
        startCapture()
    }

    private func beginCameraPermissionRequest() -> UInt64 {
        cameraPermissionLock.lock()
        cameraPermissionRequestID &+= 1
        let requestID = cameraPermissionRequestID
        cameraPermissionLock.unlock()
        return requestID
    }

    private func isCurrentCameraPermissionRequest(_ requestID: UInt64) -> Bool {
        cameraPermissionLock.lock()
        let isCurrent = cameraPermissionRequestID == requestID
        cameraPermissionLock.unlock()
        return isCurrent
    }

    private func invalidateCameraPermissionRequests() {
        cameraPermissionLock.lock()
        cameraPermissionRequestID &+= 1
        cameraPermissionLock.unlock()
    }

    private func startCapture(state: String = "Starting", message: String = "") {
        guard !shuttingDown, trackingIntent.shouldRunCapture else { return }
        guard let camera = selectedCamera() else {
            waitForCamera()
            return
        }
        resumeWhenCameraReturns = false
        waitingCameraID = nil
        captureInterrupted = false
        beginTrackingActivity()
        tearDownCapturePipeline()

        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            let desiredPreset = settings.resolution.sessionPreset
            session.sessionPreset = session.canSetSessionPreset(desiredPreset) ? desiredPreset : .medium

            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw TrackerError.configuration("The selected camera cannot be added to the capture session.")
            }
            session.addInput(input)
            currentInput = input

            let nextVideoOutput = AVCaptureVideoDataOutput()
            nextVideoOutput.alwaysDiscardsLateVideoFrames = true
            nextVideoOutput.videoSettings = [:]
            nextVideoOutput.setSampleBufferDelegate(self, queue: inferenceQueue)
            videoOutput = nextVideoOutput
            guard session.canAddOutput(nextVideoOutput) else {
                throw TrackerError.configuration("The video output cannot be added to the capture session.")
            }
            session.addOutput(nextVideoOutput)

            frameCadence.reset()
            fpsWindowStarted = ProcessInfo.processInfo.systemUptime
            fpsWindowFrames = 0
            metaCalculator.reset()
            lossHysteresis.reset()
            status = TrackerStatus(
                state: state,
                camera: camera.localizedName,
                handCount: 0,
                trackingFPS: 0,
                inferenceMilliseconds: 0,
                droppedFrames: status.droppedFrames,
                oscDestination: "\(settings.oscHost):\(settings.oscPort)",
                error: message,
                isTracking: true
            )
            trackingError = message
            refreshStatusError()
        } catch {
            tearDownCapturePipeline()
            let now = ProcessInfo.processInfo.systemUptime
            captureWatchdog.captureStarted(at: now)
            lossHysteresis.reset()
            metaCalculator.reset()
            status.state = "Recovering"
            status.camera = camera.localizedName
            status.isTracking = true
            status.handCount = 0
            status.trackingFPS = 0
            setTrackingError("Camera setup failed; retrying: \(error.localizedDescription)")
            clearPreviewOverlay()
            sendActiveHands([0, 0])
            publishStatus()
            sendTrackingStatus(appRunning: true)
            return
        }

        session.startRunning()
        captureWatchdog.captureStarted(at: ProcessInfo.processInfo.systemUptime)
        if !session.isRunning {
            status.state = "Recovering"
            setTrackingError("Camera capture started without delivering a running session; waiting to retry.")
        }
        publishStatus()
        sendTrackingStatus(appRunning: true)
    }

    private func stopCapture(sendStatus: Bool) {
        guard status.isTracking || session.isRunning || currentInput != nil else {
            status.state = "Idle"
            status.isTracking = false
            setTrackingError("")
            clearPreviewOverlay()
            publishStatus()
            return
        }

        tearDownCapturePipeline()
        captureWatchdog.stop()
        status.state = "Idle"
        status.isTracking = false
        status.handCount = 0
        status.trackingFPS = 0
        status.inferenceMilliseconds = 0
        setTrackingError("")
        metaCalculator.reset()
        lossHysteresis.reset()
        clearPreviewOverlay()
        sendActiveHands([0, 0])
        if sendStatus { sendTrackingStatus(appRunning: true) }
        publishStatus()
    }

    private func tearDownCapturePipeline() {
        let previousVideoOutput = videoOutput
        previousVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        let hasVideoOutput = previousVideoOutput.map { output in
            session.outputs.contains(where: { $0 === output })
        } ?? false
        guard currentInput != nil || hasVideoOutput else {
            videoOutput = nil
            return
        }
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        if let previousVideoOutput, hasVideoOutput {
            session.removeOutput(previousVideoOutput)
        }
        session.commitConfiguration()
        videoOutput = nil
    }

    private func rebuildCaptureSession(state: String, message: String) {
        guard !shuttingDown, trackingIntent.shouldRunCapture else { return }
        status.handCount = 0
        status.trackingFPS = 0
        clearPreviewOverlay()
        sendActiveHands([0, 0])
        startCapture(state: state, message: message)
    }

    private func waitForCamera() {
        tearDownCapturePipeline()
        captureWatchdog.stop()
        lossHysteresis.reset()
        metaCalculator.reset()
        endTrackingActivity()
        resumeWhenCameraReturns = true
        waitingCameraID = settings.cameraID.isEmpty ? nil : settings.cameraID
        status.state = "Waiting for camera"
        status.camera = "None"
        status.isTracking = trackingIntent.isRequested
        status.handCount = 0
        status.trackingFPS = 0
        setTrackingError("The selected camera is unavailable. Tracking will resume when it reconnects.")
        clearPreviewOverlay()
        sendActiveHands([0, 0])
        publishStatus()
        sendTrackingStatus(appRunning: true)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === videoOutput,
              currentInput != nil,
              trackingIntent.shouldRunCapture,
              !captureInterrupted else { return }
        let sampleArrivedAt = ProcessInfo.processInfo.systemUptime
        let wasAwaitingFirstSample = !captureWatchdog.hasReceivedSampleSinceStart
        captureWatchdog.sampleBufferArrived(at: sampleArrivedAt)
        if wasAwaitingFirstSample || status.state != "Tracking" {
            status.state = "Tracking"
            status.isTracking = true
            setTrackingError("")
            publishStatus()
            sendTrackingStatus(appRunning: true)
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sampleTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let now = sampleTime.isFinite ? sampleTime : ProcessInfo.processInfo.systemUptime
        guard frameCadence.shouldProcess(timestamp: now, targetHz: settings.cadenceHz) else { return }

        let started = ProcessInfo.processInfo.systemUptime
        let roi = centeredRegionOfInterest(zoom: settings.zoom)
        request.maximumHandCount = settings.maxHands
        request.regionOfInterest = roi
        let handler = makeImageRequestHandler(pixelBuffer: pixelBuffer, rotation: settings.rotation)
        let detectionTimestamp = ProcessInfo.processInfo.systemUptime

        do {
            try handler.perform([request])
            let mapped = try (request.results ?? []).compactMap { observation -> ([NormalizedLandmark], Float)? in
                try HandPoseMapper.landmarks(
                    from: observation,
                    minimumConfidence: settings.minimumConfidence
                )
            }
            .sorted { palmX($0.0) < palmX($1.0) }
            .prefix(settings.maxHands)

            let measuredDetections = mapped.enumerated().map { slot, item in
                HandDetection(
                    landmarks: item.0,
                    meta: metaCalculator.compute(
                        landmarks: item.0,
                        score: item.1,
                        slot: slot,
                        timestamp: detectionTimestamp
                    )
                )
            }
            let detections = lossHysteresis.stabilize(
                detections: measuredDetections,
                timestamp: detectionTimestamp
            )
            let handCountChanged = status.handCount != detections.count
            status.handCount = detections.count
            if handCountChanged, detections.isEmpty { metaCalculator.reset() }
            send(detections: detections)
            if handCountChanged {
                // /hands/active commits the complete frame for existing OSC
                // receivers. Follow its edge with an immediate status packet
                // so hand-present/absent UI remains correct even if one UDP
                // callback is missed between the steady 1 Hz heartbeats.
                sendTrackingStatus(appRunning: true)
            }
            setTrackingError("")
            publishPreviewOverlay(detections: detections, pixelBuffer: pixelBuffer)
        } catch {
            let detections = lossHysteresis.stabilize(detections: [], timestamp: detectionTimestamp)
            let handCountChanged = status.handCount != detections.count
            status.handCount = detections.count
            if handCountChanged, detections.isEmpty { metaCalculator.reset() }
            setTrackingError("Vision: \(error.localizedDescription)")
            send(detections: detections)
            if handCountChanged { sendTrackingStatus(appRunning: true) }
            publishPreviewOverlay(detections: detections, pixelBuffer: pixelBuffer)
        }

        status.inferenceMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        // A long Vision request is still proof that the camera pipeline was
        // alive for this frame. Refresh liveness at completion so the watchdog
        // does not misclassify slow inference as a capture stall.
        captureWatchdog.sampleBufferArrived(at: ProcessInfo.processInfo.systemUptime)
        fpsWindowFrames += 1
        updateFPS(now: ProcessInfo.processInfo.systemUptime)
        publishStatus(throttled: true)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === videoOutput, currentInput != nil else { return }
        status.droppedFrames += 1
    }

    private func send(detections: [HandDetection]) {
        var active: [Int32] = [0, 0]
        var messages: [(address: String, arguments: [OSCArgument])] = []
        for (slot, detection) in detections.prefix(2).enumerated() {
            guard detection.landmarks.count == 21 else { continue }
            active[slot] = 1
            messages.append((
                address: "/hand/\(slot)/landmarks",
                arguments: OSCContract.landmarkArguments(detection.landmarks)
            ))
            messages.append((
                address: "/hand/\(slot)/meta",
                arguments: OSCContract.metaArguments(detection.meta)
            ))
        }
        messages.append((
            address: "/hands/active",
            arguments: active.map(OSCArgument.int32)
        ))
        osc.sendBatch(messages, coalescingKey: "tracking-frame")
    }

    private func publishPreviewOverlay(
        detections: [HandDetection],
        pixelBuffer: CVPixelBuffer
    ) {
        previewPublishingLock.lock()
        guard previewPublishingEnabled, onPreviewOverlay != nil else {
            previewPublishingLock.unlock()
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width > 0, height > 0 {
            lastPreviewAspectRatio = CGFloat(width) / CGFloat(height)
        }
        pendingPreviewFrame = PreviewOverlayFrame(
            hands: detections.prefix(2).map(\.landmarks),
            sourceAspectRatio: lastPreviewAspectRatio
        )
        guard !previewDeliveryScheduled else {
            previewPublishingLock.unlock()
            return
        }
        previewDeliveryScheduled = true
        previewPublishingLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.deliverLatestPreviewFrame() }
    }

    private func clearPreviewOverlay() {
        previewPublishingLock.lock()
        guard previewPublishingEnabled, onPreviewOverlay != nil else {
            previewPublishingLock.unlock()
            return
        }
        pendingPreviewFrame = PreviewOverlayFrame(
            hands: [],
            sourceAspectRatio: lastPreviewAspectRatio
        )
        guard !previewDeliveryScheduled else {
            previewPublishingLock.unlock()
            return
        }
        previewDeliveryScheduled = true
        previewPublishingLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.deliverLatestPreviewFrame() }
    }

    private func deliverLatestPreviewFrame() {
        previewPublishingLock.lock()
        let callback = previewPublishingEnabled ? onPreviewOverlay : nil
        let frame = previewPublishingEnabled ? pendingPreviewFrame : nil
        pendingPreviewFrame = nil
        previewDeliveryScheduled = false
        previewPublishingLock.unlock()
        if let callback, let frame { callback(frame) }
    }

    private func sendActiveHands(_ active: [Int32]) {
        osc.sendBatch(
            [(address: "/hands/active", arguments: active.map(OSCArgument.int32))],
            coalescingKey: "tracking-frame"
        )
    }

    private func sendTrackingStatus(appRunning: Bool) {
        updateHeartbeatSnapshot(appRunning: appRunning)
        sendHeartbeatSnapshot()
    }

    private func updateHeartbeatSnapshot(appRunning: Bool = true) {
        let next = TrackingHeartbeatSnapshot(
            appRunning: appRunning,
            trackingActive: appRunning &&
                trackingIntent.shouldRunCapture &&
                captureWatchdog.hasReceivedSampleSinceStart,
            handCount: appRunning ? status.handCount : 0,
            trackingFPS: appRunning ? status.trackingFPS : 0
        )
        heartbeatLock.lock()
        heartbeatSnapshot = next
        heartbeatLock.unlock()
    }

    private func sendHeartbeatSnapshot() {
        heartbeatLock.lock()
        let snapshot = heartbeatSnapshot
        heartbeatLock.unlock()
        osc.send(
            address: "/tracking/status",
            arguments: OSCContract.trackingStatusArguments(
                appRunning: snapshot.appRunning,
                trackingActive: snapshot.trackingActive,
                handCount: snapshot.handCount,
                trackingFPS: snapshot.trackingFPS
            )
        )
    }

    private func updateFPS(now: TimeInterval) {
        let elapsed = now - fpsWindowStarted
        guard elapsed >= 1 else { return }
        status.trackingFPS = Double(fpsWindowFrames) / elapsed
        fpsWindowFrames = 0
        fpsWindowStarted = now
    }

    private func centeredRegionOfInterest(zoom: Double) -> CGRect {
        let size = 1 / min(10, max(1, zoom))
        return CGRect(x: (1 - size) / 2, y: (1 - size) / 2, width: size, height: size)
    }

    private func makeImageRequestHandler(
        pixelBuffer: CVPixelBuffer,
        rotation: Double
    ) -> VNImageRequestHandler {
        if let quarterTurns = ImageRotation.discreteQuarterTurns(rotation) {
            let orientation: CGImagePropertyOrientation
            switch quarterTurns {
            case 1: orientation = .right
            case 2: orientation = .down
            case 3: orientation = .left
            default: orientation = .up
            }
            return VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation,
                options: [:]
            )
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let radians = CGFloat(-ImageRotation.normalizedDegrees(rotation) * .pi / 180)
        let center = CGPoint(x: source.extent.midX, y: source.extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        var rotated = source.transformed(by: transform)
        rotated = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
        return VNImageRequestHandler(ciImage: rotated, orientation: .up, options: [:])
    }

    private func checkCaptureHealth() {
        guard !shuttingDown,
              trackingIntent.shouldRunCapture,
              !captureInterrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard captureWatchdog.shouldRecover(at: now) else { return }

        captureWatchdog.recordRecoveryAttempt(at: now)
        let attempt = captureWatchdog.recoveryAttemptCount
        rebuildCaptureSession(
            state: "Recovering",
            message: "No camera frame arrived; rebuilding capture (attempt \(attempt))."
        )
    }

    private func beginTrackingActivity() {
        guard trackingActivity == nil, trackingIntent.shouldRunCapture else { return }
        trackingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Continuous hand tracking and camera frame delivery"
        )
    }

    private func endTrackingActivity() {
        guard let trackingActivity else { return }
        ProcessInfo.processInfo.endActivity(trackingActivity)
        self.trackingActivity = nil
    }

    private func palmX(_ landmarks: [NormalizedLandmark]) -> Float {
        guard landmarks.count == 21 else { return 0 }
        return [0, 5, 9, 13, 17].map { landmarks[$0].x }.reduce(0, +) / 5
    }

    private func fail(_ message: String) {
        status.state = "Error"
        setTrackingError(message)
        status.isTracking = false
        status.handCount = 0
        sendActiveHands([0, 0])
        clearPreviewOverlay()
        publishStatus()
        sendTrackingStatus(appRunning: true)
    }

    private func setTrackingError(_ message: String) {
        trackingError = message
        refreshStatusError()
    }

    private func refreshStatusError() {
        status.error = [trackingError, oscError]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private func publishStatus(throttled: Bool = false) {
        updateHeartbeatSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        if throttled, now - lastStatusPublish < 0.25 { return }
        lastStatusPublish = now
        let snapshot = status
        statusPublishingLock.lock()
        pendingPublishedStatus = snapshot
        guard !statusDeliveryScheduled else {
            statusPublishingLock.unlock()
            return
        }
        statusDeliveryScheduled = true
        statusPublishingLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.deliverLatestStatus() }
    }

    private func deliverLatestStatus() {
        statusPublishingLock.lock()
        let snapshot = pendingPublishedStatus
        pendingPublishedStatus = nil
        statusDeliveryScheduled = false
        statusPublishingLock.unlock()
        if let snapshot { onStatus?(snapshot) }
    }
}

private enum TrackerError: LocalizedError {
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        }
    }
}

private extension CaptureResolution {
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .low: return .low
        case .vga: return .vga640x480
        case .hd: return .hd1280x720
        }
    }
}
