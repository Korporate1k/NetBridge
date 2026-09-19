import SwiftUI
import UIKit
import AVFoundation

/// Camera-based counterpart to `QRCodeView.swift`'s `QRCodeSheet`: scans a
/// code produced by that view (or by another device's Client tab) and hands
/// the decoded string back once, so a second device can be paired to the
/// same SOCKS5 server without typing host/port/credentials in by hand.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    enum ScanSetupError: Equatable {
        case permissionDenied
        case restricted
        case noCameraAvailable
        case setupFailed
    }

    var onScan: ((String) -> Void)?
    var onError: ((ScanSetupError) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccessAndConfigure()
    }

    /// Camera access is never implicitly granted just by AVFoundation's
    /// built-in prompt: without this explicit check, a denied/restricted
    /// camera (or any later session-setup failure) used to leave the sheet
    /// as a silent black screen with no capture ever starting — indistinguishable
    /// from "still looking for a code." Every branch below now reports a real
    /// state back to `onError` instead of silently no-oping.
    private func requestCameraAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onError?(.permissionDenied)
                    }
                }
            }
        case .restricted:
            onError?(.restricted)
        case .denied:
            onError?(.permissionDenied)
        @unknown default:
            onError?(.permissionDenied)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?(.noCameraAvailable)
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onError?(.setupFailed)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?(.setupFailed)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }
        onScan?(code)
    }
}

struct QRScannerViewRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (QRScannerViewController.ScanSetupError) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

struct QRScannerSheet: View {
    /// Called once with a successfully decoded configuration; the caller
    /// dismisses the sheet itself once it applies the result.
    let onScanned: (ClientConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanError: String?
    @State private var setupError: QRScannerViewController.ScanSetupError?

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                if setupError == nil {
                    QRScannerViewRepresentable(onScan: handleScan, onError: handleSetupError)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                if let setupError {
                    VStack(spacing: 12) {
                        Text(setupErrorMessage(setupError))
                            .font(.footnote)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        if setupError == .permissionDenied || setupError == .restricted {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 32)
                } else if let scanError {
                    Text(scanError)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handleScan(_ code: String) {
        guard let config = ClientConfiguration(uriString: code) else {
            scanError = "That QR code isn't a LocalProxy server configuration. Keep scanning."
            return
        }
        scanError = nil
        onScanned(config)
    }

    private func handleSetupError(_ error: QRScannerViewController.ScanSetupError) {
        setupError = error
    }

    private func setupErrorMessage(_ error: QRScannerViewController.ScanSetupError) -> String {
        switch error {
        case .permissionDenied:
            return "Camera access denied — enable it in Settings to scan a QR code."
        case .restricted:
            return "Camera access is restricted on this device."
        case .noCameraAvailable:
            return "No camera available on this device."
        case .setupFailed:
            return "Couldn't start the camera. Try again."
        }
    }
}
