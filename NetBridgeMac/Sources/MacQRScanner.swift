import SwiftUI
import AppKit
import AVFoundation
import Vision

/// Camera QR scanner for the Mac — the counterpart of the iOS `QRScannerSheet`. Frames from the
/// default camera (built-in, external or a Continuity Camera iPhone) go through Vision's barcode
/// detector; `AVCaptureMetadataOutput`, which the iOS scanner uses, isn't dependable on the Mac.
struct MacQRScannerSheet: View {
    let onScanned: (String) -> Void

    @StateObject private var scanner = QRCameraScanner()
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan QR Code").font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black)
                switch scanner.state {
                case .running, .starting:
                    CameraPreview(session: scanner.session)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .denied:
                    placeholder("Camera access is off. Allow NetBridge in System Settings → Privacy & Security → Camera.")
                case .noCamera:
                    placeholder("No camera found.")
                case .failed(let reason):
                    placeholder("Couldn't start the camera: \(reason)")
                }
            }
            .frame(width: 400, height: 300)

            Text(message ?? "Point the camera at the NetBridge QR code on the other device.")
                .font(.callout)
                .foregroundColor(message == nil ? .secondary : .orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 448)
        .onAppear {
            scanner.onCode = handle
            scanner.start()
        }
        .onDisappear { scanner.stop() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private func handle(_ code: String) {
        guard ClientConfiguration(uriString: code) != nil else {
            message = "That QR code isn't a NetBridge server. Keep scanning."
            return
        }
        scanner.stop()
        dismiss()
        onScanned(code)
    }
}

/// Owns the capture session and runs QR detection on its frames. `onCode` is called on the main
/// queue, once per distinct payload, until `stop()`.
final class QRCameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable {
        case starting, running, denied, noCamera
        case failed(String)
    }

    @Published private(set) var state: State = .starting
    var onCode: ((String) -> Void)?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "netbridge.qrscanner")
    private var configured = false
    private var lastPayload: String?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startSession() } else { self?.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        onCode = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func startSession() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard let device = AVCaptureDevice.default(for: .video) else {
                    DispatchQueue.main.async { self.state = .noCamera }
                    return
                }
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        DispatchQueue.main.async { self.state = .failed("the camera is in use or unsupported.") }
                        return
                    }
                    self.session.addInput(input)
                    self.session.addOutput(output)
                    self.session.commitConfiguration()
                    self.configured = true
                } catch {
                    DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
                    return
                }
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.state = .running }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        guard let payload = request.results?.compactMap(\.payloadStringValue).first,
              payload != lastPayload else { return }
        lastPayload = payload
        DispatchQueue.main.async { [weak self] in self?.onCode?(payload) }
    }
}

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
