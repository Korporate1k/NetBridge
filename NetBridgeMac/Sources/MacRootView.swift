import SwiftUI

/// Sidebar + detail shell: the iOS app's Dashboard and Client tabs as sidebar rows.
struct MacRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case client = "Client"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
            case .client: return "network"
            }
        }
    }

    @EnvironmentObject private var model: MacClientModel
    @State private var selection: Section? = .client

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch selection ?? .client {
            case .dashboard: MacDashboardView()
            case .client: MacClientView()
            }
        }
    }
}
