import AVFoundation
import SwiftUI
import UIKit

/// Polished QR scanner with a frosted frame overlay, success haptic,
/// and smooth scan animation. Calls `onScan` with the decoded string.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var hasScanned = false
    private var frameLayer: CAShapeLayer?
    private var pulseLayer: CAShapeLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showError("Camera unavailable")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        addOverlay()
        addControls()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first(where: { $0 is AVCaptureVideoPreviewLayer })?.frame = view.bounds
        layoutOverlay()
    }

    // MARK: - Overlay

    private let dimLayer = CALayer()
    private let cutoutSize: CGFloat = 240

    private func addOverlay() {
        dimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        view.layer.addSublayer(dimLayer)

        let frame = CAShapeLayer()
        frame.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        frame.fillColor = UIColor.clear.cgColor
        frame.lineWidth = 2.5
        frame.lineCap = .round
        self.frameLayer = frame
        view.layer.addSublayer(frame)

        let pulse = CAShapeLayer()
        pulse.strokeColor = UIColor(red: 10/255, green: 132/255, blue: 255/255, alpha: 0.6).cgColor
        pulse.fillColor = UIColor.clear.cgColor
        pulse.lineWidth = 2.0
        pulse.opacity = 0
        self.pulseLayer = pulse
        view.layer.addSublayer(pulse)

        startPulseAnimation()
    }

    private func layoutOverlay() {
        let bounds = view.bounds
        dimLayer.frame = bounds

        let center = CGPoint(x: bounds.midX, y: bounds.midY - 40)
        let rect = CGRect(
            x: center.x - cutoutSize / 2,
            y: center.y - cutoutSize / 2,
            width: cutoutSize,
            height: cutoutSize
        )

        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(roundedRect: rect, cornerRadius: 20).reversing())
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        dimLayer.mask = mask

        let cornerLength: CGFloat = 32
        let framePath = UIBezierPath()
        let r: CGFloat = 20
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + cornerLength), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + cornerLength, y: rect.minY)),
            (CGPoint(x: rect.maxX - cornerLength, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + cornerLength)),
            (CGPoint(x: rect.maxX, y: rect.maxY - cornerLength), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - cornerLength, y: rect.maxY)),
            (CGPoint(x: rect.minX + cornerLength, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - cornerLength)),
        ]
        for (start, corner, end) in corners {
            framePath.move(to: start)
            framePath.addLine(to: CGPoint(
                x: corner.x + (corner.x == rect.minX ? r : -r) * (corner.x == start.x ? 0 : 1),
                y: corner.y + (corner.y == rect.minY ? r : -r) * (corner.y == start.y ? 0 : 1)
            ))
            framePath.addQuadCurve(to: CGPoint(
                x: corner.x + (end.x > corner.x ? r : (end.x < corner.x ? -r : 0)),
                y: corner.y + (end.y > corner.y ? r : (end.y < corner.y ? -r : 0))
            ), controlPoint: corner)
            framePath.addLine(to: end)
        }
        frameLayer?.path = framePath.cgPath

        let pulseRect = rect.insetBy(dx: -6, dy: -6)
        pulseLayer?.path = UIBezierPath(roundedRect: pulseRect, cornerRadius: 24).cgPath
    }

    private func startPulseAnimation() {
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.6
        opacityAnim.toValue = 0.0
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 1.06
        let group = CAAnimationGroup()
        group.animations = [opacityAnim, scaleAnim]
        group.duration = 2.0
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer?.add(group, forKey: "pulse")
    }

    // MARK: - Controls

    private func addControls() {
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        cancel.tintColor = .white
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)

        let hint = UILabel()
        hint.text = "Point at the brain's QR code"
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = .white.withAlphaComponent(0.8)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
    }

    @objc private func cancelTapped() {
        session.stopRunning()
        dismiss(animated: true)
    }

    // MARK: - Scan Result

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasScanned,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue, !value.isEmpty
        else { return }
        hasScanned = true
        session.stopRunning()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        frameLayer?.strokeColor = UIColor(red: 48/255, green: 209/255, blue: 88/255, alpha: 1).cgColor
        pulseLayer?.removeAllAnimations()
        pulseLayer?.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onScan?(value)
        }
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
