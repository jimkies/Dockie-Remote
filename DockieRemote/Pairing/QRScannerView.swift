import AVFoundation
import SwiftUI

/// Camera preview that reports the first QR code it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        vc.onCode = onCode
    }
}

/// Holds the capture session so it can be started and stopped off the main thread.
private final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "dockie.remote.camera")
    func start() { queue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let box = SessionBox()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              box.session.canAddInput(input) else { return }
        box.session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard box.session.canAddOutput(output) else { return }
        box.session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: box.session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastCode = nil
        box.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        box.stop()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        // The delegate queue is .main.
        MainActor.assumeIsolated { self.found(code) }
    }

    private func found(_ code: String) {
        // Don't report the same code again every frame while it stays in view.
        guard code != lastCode else { return }
        lastCode = code
        onCode?(code)
        // After a short pause the same code can be reported again, e.g. after an error was shown.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.lastCode == code { self?.lastCode = nil }
        }
    }
}
