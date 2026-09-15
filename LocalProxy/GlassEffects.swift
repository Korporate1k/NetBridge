import SwiftUI

/// Centralizes the "modern glass" look so every custom card/button in the
/// app picks up real Liquid Glass on capable devices without duplicating the
/// availability branch everywhere. Deployment target stays iOS 15 — below
/// iOS 26 this falls back to a translucent Material, which needs no
/// availability check at all.
extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial))
        }
    }

    /// The Start/Stop button's style: `.glassProminent` on iOS 26+ (a
    /// prominent, tintable glass pill), `.borderedProminent` below.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
