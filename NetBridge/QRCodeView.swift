import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string as a QR code using CoreImage's built-in generator (no
/// external dependency) so a second device can scan the proxy's address:port
/// instead of typing it in.
enum QRCode {
    static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Shows *this device's own* proxy server as a plain `ip:port` QR code — the
/// format `ClientConfiguration(uriString:)` (and so the Client tab's scanner)
/// accepts. Used by both the Dashboard and the Client tab. Observes the server
/// directly so the code tracks address/port changes while open, and never
/// encodes a placeholder when no IPv4 address is known yet.
struct QRCodeSheet: View {
    @ObservedObject var server: ProxyServer
    @Environment(\.dismiss) private var dismiss

    private var address: String? {
        server.localIP.map { "\($0):\(server.port)" }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let address, let image = QRCode.image(for: address) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .padding(20)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if address == nil {
                    Text("No network address yet — connect to Wi-Fi or turn on Personal Hotspot.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                } else {
                    Text("Couldn't generate a QR code.")
                        .foregroundColor(.secondary)
                }
                if let address {
                    Text(address)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
            .glassCard(cornerRadius: 24)
            .padding()
            .navigationTitle("Scan to Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
