import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR generation and decoding via CoreImage (no dependencies) — the Mac
/// counterpart of the iOS camera scanner (`QRScannerView`) and `QRCode` helper.
enum QRSupport {
    static func image(for string: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Decodes the first QR code found in the image file at `url`.
    static func decode(imageAt url: URL) -> String? {
        guard let ciImage = CIImage(contentsOf: url) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
