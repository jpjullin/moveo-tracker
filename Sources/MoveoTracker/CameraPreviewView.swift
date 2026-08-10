import AppKit
import AVFoundation
import MoveoTrackerCore
import QuartzCore

private final class ResolutionBadgeView: NSView {
    private let label: NSTextField

    var title: String {
        didSet {
            label.stringValue = title
            setAccessibilityValue(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    init(title: String) {
        self.title = title
        self.label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Capture resolution")
        setAccessibilityValue(title)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 20, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

final class CameraPreviewView: NSView {
    private static let overlayColors: [NSColor] = [
        .systemCyan, .systemPink, .systemGreen, .systemOrange,
        .systemPurple, .systemYellow, .systemBlue, .systemMint
    ]

    private struct OverlayLayers {
        let skeleton: CAShapeLayer
        let joints: CAShapeLayer
    }

    private let viewportLayer = CALayer()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let resolutionBadge = ResolutionBadgeView(title: CaptureResolution.vga.displayName)
    private var overlayLayers: [OverlayLayers] = []
    private var displayedDetections: [PreviewDetection] = []
    private weak var captureSession: AVCaptureSession?
    private var rotationDegrees: Double = 0
    private var zoom: Double = 1
    private var sourceAspectRatio: CGFloat = 4 / 3
    private var presentationRect = CGRect.zero

    init(session: AVCaptureSession) {
        captureSession = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        layer?.masksToBounds = true
        viewportLayer.masksToBounds = true
        previewLayer.videoGravity = .resizeAspect
        viewportLayer.addSublayer(previewLayer)
        ensureOverlayLayerCount(2)
        layer?.addSublayer(viewportLayer)
        resolutionBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resolutionBadge)
        NSLayoutConstraint.activate([
            resolutionBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            resolutionBadge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            resolutionBadge.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sourceSize = CGSize(width: sourceAspectRatio * 1_000, height: 1_000)
        viewportLayer.frame = bounds
        viewportLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.bounds = CGRect(origin: .zero, size: sourceSize)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for layers in overlayLayers {
            layers.skeleton.frame = viewportLayer.bounds
            layers.joints.frame = viewportLayer.bounds
        }
        applyTransform()
        renderDetections()
        CATransaction.commit()
    }

    func attach() {
        guard previewLayer.session == nil else { return }
        previewLayer.session = captureSession
    }

    func detach() {
        clearDetections()
        previewLayer.session = nil
    }

    func update(
        rotation: Double,
        zoom: Double,
        resolution: CaptureResolution
    ) {
        rotationDegrees = ImageRotation.normalizedDegrees(rotation)
        self.zoom = min(10, max(1, zoom))
        sourceAspectRatio = resolution.aspectRatio
        resolutionBadge.title = resolution.displayName
        needsLayout = true
    }

    func updateDetections(_ detections: [PreviewDetection], sourceAspectRatio: CGFloat) {
        guard previewLayer.session != nil else { return }
        displayedDetections = detections
        ensureOverlayLayerCount(detections.count)
        let validAspect = sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? sourceAspectRatio
            : self.sourceAspectRatio
        if abs(validAspect - self.sourceAspectRatio) > 0.000_1 {
            self.sourceAspectRatio = validAspect
            needsLayout = true
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderDetections()
            CATransaction.commit()
        }
    }

    func clearDetections() {
        displayedDetections.removeAll(keepingCapacity: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layers in overlayLayers {
            layers.skeleton.path = nil
            layers.joints.path = nil
        }
        CATransaction.commit()
    }

    private func applyTransform() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radians = CGFloat(-rotationDegrees * .pi / 180)
        let rotatedWidth = abs(previewLayer.bounds.width * cos(radians))
            + abs(previewLayer.bounds.height * sin(radians))
        presentationRect = PreviewCoverageGeometry.coverRect(
            container: viewportLayer.bounds.size,
            source: previewLayer.bounds.size,
            rotationDegrees: rotationDegrees,
            zoom: zoom
        )
        let scale = rotatedWidth > 0 ? presentationRect.width / rotatedWidth : 1
        previewLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: radians).scaledBy(x: scale, y: scale)
        )
    }

    private func renderDetections() {
        let detectionRect = viewportLayer.bounds
        guard detectionRect.width > 0, detectionRect.height > 0 else { return }

        for slot in overlayLayers.indices {
            let layers = overlayLayers[slot]
            guard slot < displayedDetections.count else {
                layers.skeleton.path = nil
                layers.joints.path = nil
                continue
            }

            let detection = displayedDetections[slot]
            let landmarks = detection.landmarks
            // Vision reports points relative to the request ROI. That ROI is
            // exactly the visible frame after zoom, rotation, and aspect crop,
            // so detections map to the viewport—not the enlarged source layer.
            let points = HandOverlayGeometry.points(for: landmarks, in: detectionRect.size)
                .map { point in
                    CGPoint(
                        x: point.x + detectionRect.minX,
                        y: point.y + detectionRect.minY
                    )
                }
            // HandPoseMapper uses an all-zero point for joints that did not
            // meet the confidence threshold. Keep that OSC sentinel, but do
            // not connect it to the preview corner.
            let drawable = landmarks.map(HandOverlayGeometry.isDrawable)
            let skeletonPath = CGMutablePath()
            for connection in detection.connections {
                guard points.indices.contains(connection.start),
                      points.indices.contains(connection.end) else { continue }
                guard drawable[connection.start], drawable[connection.end] else { continue }
                skeletonPath.move(to: points[connection.start])
                skeletonPath.addLine(to: points[connection.end])
            }

            let jointPath = CGMutablePath()
            let radius: CGFloat = 3.5
            for (index, point) in points.enumerated() where drawable[index] {
                jointPath.addEllipse(in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
            layers.skeleton.path = skeletonPath
            layers.joints.path = jointPath
        }
    }

    private func ensureOverlayLayerCount(_ count: Int) {
        guard count > overlayLayers.count else { return }
        for index in overlayLayers.count..<count {
            let color = Self.overlayColors[index % Self.overlayColors.count]
            let skeleton = CAShapeLayer()
            skeleton.fillColor = nil
            skeleton.strokeColor = color.withAlphaComponent(0.95).cgColor
            skeleton.lineWidth = 2.5
            skeleton.lineCap = .round
            skeleton.lineJoin = .round

            let joints = CAShapeLayer()
            joints.fillColor = color.cgColor
            joints.strokeColor = NSColor.black.withAlphaComponent(0.8).cgColor
            joints.lineWidth = 1

            viewportLayer.addSublayer(skeleton)
            viewportLayer.addSublayer(joints)
            overlayLayers.append(OverlayLayers(skeleton: skeleton, joints: joints))
        }
        for layers in overlayLayers {
            layers.skeleton.frame = viewportLayer.bounds
            layers.joints.frame = viewportLayer.bounds
        }
    }

}
