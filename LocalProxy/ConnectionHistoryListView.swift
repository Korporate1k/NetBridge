import SwiftUI

struct ConnectionHistoryListView: View {
    @ObservedObject var history: ConnectionHistory
    @State private var searchText = ""
    /// nil = All modes, "" = "No location" (entries with no country match).
    @State private var modeFilter: String?
    @State private var countryFilter: String?

    /// Modes actually present in history right now, sorted — so the filter
    /// menu never offers a mode (e.g. a removed listener type) with nothing
    /// to show for it.
    private var availableModes: [String] {
        Array(Set(history.entries.map(\.mode))).sorted()
    }

    private var availableCountries: [(code: String, name: String)] {
        var seen: [String: String] = [:]
        for entry in history.entries {
            guard let code = entry.countryCode else { continue }
            seen[code] = entry.countryName ?? code
        }
        return seen.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    private var filteredEntries: [ConnectionSummary] {
        history.entries.filter { entry in
            if let modeFilter, entry.mode != modeFilter { return false }
            if let countryFilter, entry.countryCode != countryFilter { return false }
            guard !searchText.isEmpty else { return true }
            let haystack = [entry.target, entry.destinationIP, entry.sniffedHost, entry.countryName, entry.city]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filtersActive: Bool { modeFilter != nil || countryFilter != nil }

    var body: some View {
        List {
            if history.entries.isEmpty {
                    Text("No connections closed yet this session.")
                        .foregroundColor(.secondary)
                } else if filteredEntries.isEmpty {
                    Text("No connections match the current filters.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.target)
                                .font(.body.weight(.semibold))
                            if let ip = entry.destinationIP, !entry.target.hasPrefix(ip) {
                                Text(ip)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let sniffed = entry.sniffedHost, !entry.target.hasPrefix(sniffed) {
                                Label(sniffed, systemImage: "eye")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let country = entry.countryName ?? entry.countryCode {
                                Text("\(flagEmoji(entry.countryCode)) \(country)\(entry.city.map { ", \($0)" } ?? "")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(entry.mode) · \(formatBytes(entry.bytesUp)) up / \(formatBytes(entry.bytesDown)) down · \(String(format: "%.1fs", entry.durationMs / 1000))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatLastSeen(entry.closedAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Host, IP, or location")
            .safeAreaInset(edge: .bottom) {
                if !history.entries.isEmpty {
                    Text("IP geolocation © DB-IP.com, CC BY 4.0")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Recent Connections")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Mode", selection: $modeFilter) {
                            Text("All modes").tag(String?.none)
                            ForEach(availableModes, id: \.self) { mode in
                                Text(mode).tag(String?.some(mode))
                            }
                        }
                        Picker("Location", selection: $countryFilter) {
                            Text("All locations").tag(String?.none)
                            ForEach(availableCountries, id: \.code) { entry in
                                Text("\(flagEmoji(entry.code)) \(entry.name)").tag(String?.some(entry.code))
                            }
                        }
                        if filtersActive {
                            Button("Clear Filters", role: .destructive) {
                                modeFilter = nil
                                countryFilter = nil
                            }
                        }
                    } label: {
                        Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .disabled(history.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { history.clear() }
                        .disabled(history.entries.isEmpty)
                }
            }
    }

    /// Regional-indicator-symbol trick: offsetting each ASCII letter by
    /// `0x1F1E6 - 'A'` composes the two-letter code into a flag emoji.
    private func flagEmoji(_ countryCode: String?) -> String {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return "🌐" }
        var scalars = String.UnicodeScalarView()
        for c in code.unicodeScalars {
            guard let scalar = Unicode.Scalar(0x1F1E6 + (c.value - Unicode.Scalar("A").value)) else { return "🌐" }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
