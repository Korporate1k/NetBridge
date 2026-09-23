import SwiftUI

/// A minimal hand-rolled line graph (no `Charts` framework — that needs iOS
/// 16+, and this project's deployment target is iOS 15.0) showing recent
/// upload/download throughput, consistent with the existing custom
/// `ShareBar` in `DevicesView.swift`.
struct UsageGraphView: View {
    let samples: [UsageSample]

    private var maxRate: Double {
        max(samples.map { max($0.up, $0.down) }.max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label("Download", systemImage: "circle.fill").labelStyle(.compact(.blue))
                Label("Upload", systemImage: "circle.fill").labelStyle(.compact(.indigo))
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if samples.count < 2 {
                Text("Graph fills in once traffic starts flowing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                GeometryReader { geometry in
                    ZStack {
                        line(for: \.down, color: .blue, geometry: geometry)
                        line(for: \.up, color: .indigo, geometry: geometry)
                    }
                }
                .frame(height: 80)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func line(for keyPath: KeyPath<UsageSample, Double>, color: Color, geometry: GeometryProxy) -> some View {
        let width = geometry.size.width
        let height = geometry.size.height
        let count = samples.count
        return Path { path in
            for (index, sample) in samples.enumerated() {
                let x = count > 1 ? width * CGFloat(index) / CGFloat(count - 1) : 0
                let fraction = min(max(sample[keyPath: keyPath] / maxRate, 0), 1)
                let y = height - (height * CGFloat(fraction))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

private extension LabelStyle where Self == CompactColorLabelStyle {
    static func compact(_ color: Color) -> CompactColorLabelStyle { CompactColorLabelStyle(color: color) }
}

private struct CompactColorLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundColor(color).font(.system(size: 8))
            configuration.title
        }
    }
}
