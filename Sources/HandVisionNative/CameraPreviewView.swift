import AppKit
import AVFoundation
import HandVisionCore
import QuartzCore

final class CameraPreviewView: NSView {
    private struct HandLayers {
        let skeleton: CAShapeLayer
        let joints: CAShapeLayer
    }

    private let viewportLayer = CALayer()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var handLayers: [HandLayers] = []
    private var displayedHands: [[NormalizedLandmark]] = []
    private weak var captureSession: AVCaptureSession?
    private var rotationDegrees: Double = 0
    private var zoom: Double = 1
    private var sourceAspectRatio: CGFloat = 4 / 3

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
        for color in [NSColor.systemCyan, NSColor.systemPink] {
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
            handLayers.append(HandLayers(skeleton: skeleton, joints: joints))
        }
        layer?.addSublayer(viewportLayer)
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
        let radians = CGFloat(-rotationDegrees * .pi / 180)
        let rotatedWidth = abs(sourceSize.width * cos(radians))
            + abs(sourceSize.height * sin(radians))
        let rotatedHeight = abs(sourceSize.width * sin(radians))
            + abs(sourceSize.height * cos(radians))
        let viewportScale = min(bounds.width / rotatedWidth, bounds.height / rotatedHeight)
        let viewportSize = CGSize(
            width: rotatedWidth * viewportScale,
            height: rotatedHeight * viewportScale
        )
        viewportLayer.bounds = CGRect(origin: .zero, size: viewportSize)
        viewportLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.bounds = CGRect(origin: .zero, size: sourceSize)
        previewLayer.position = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        for layers in handLayers {
            layers.skeleton.frame = viewportLayer.bounds
            layers.joints.frame = viewportLayer.bounds
        }
        applyTransform()
        renderHands()
        CATransaction.commit()
    }

    func attach() {
        guard previewLayer.session == nil else { return }
        previewLayer.session = captureSession
    }

    func detach() {
        clearHands()
        previewLayer.session = nil
    }

    func update(rotation: Double, zoom: Double, resolution: CaptureResolution) {
        rotationDegrees = ImageRotation.normalizedDegrees(rotation)
        self.zoom = min(10, max(1, zoom))
        sourceAspectRatio = resolution == .hd ? 16 / 9 : 4 / 3
        needsLayout = true
    }

    func updateHands(_ hands: [[NormalizedLandmark]], sourceAspectRatio: CGFloat) {
        guard previewLayer.session != nil else { return }
        displayedHands = Array(hands.prefix(2))
        let validAspect = sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? sourceAspectRatio
            : self.sourceAspectRatio
        if abs(validAspect - self.sourceAspectRatio) > 0.000_1 {
            self.sourceAspectRatio = validAspect
            needsLayout = true
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderHands()
            CATransaction.commit()
        }
    }

    func clearHands() {
        displayedHands.removeAll(keepingCapacity: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layers in handLayers {
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
        let rotatedHeight = abs(previewLayer.bounds.width * sin(radians))
            + abs(previewLayer.bounds.height * cos(radians))
        let fitScale = min(
            viewportLayer.bounds.width / rotatedWidth,
            viewportLayer.bounds.height / rotatedHeight
        )
        let scale = fitScale * CGFloat(zoom)
        previewLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: radians).scaledBy(x: scale, y: scale)
        )
    }

    private func renderHands() {
        let size = viewportLayer.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        for slot in handLayers.indices {
            let layers = handLayers[slot]
            guard slot < displayedHands.count, displayedHands[slot].count == 21 else {
                layers.skeleton.path = nil
                layers.joints.path = nil
                continue
            }

            let landmarks = displayedHands[slot]
            let points = HandOverlayGeometry.points(for: landmarks, in: size)
            // HandPoseMapper uses an all-zero point for joints that did not
            // meet the confidence threshold. Keep that OSC sentinel, but do
            // not connect it to the preview corner.
            let drawable = landmarks.map(HandOverlayGeometry.isDrawable)
            let skeletonPath = CGMutablePath()
            for connection in HandSkeleton.connections {
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

}
