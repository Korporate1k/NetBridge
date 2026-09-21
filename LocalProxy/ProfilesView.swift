import SwiftUI
import CoreLocation

/// Save/switch between a few listener + DoH + keep-alive setups. Applying a
/// profile is disabled while the proxy is running, matching the existing
/// port `Stepper`'s `.disabled(server.isRunning)` pattern in `DashboardView`.
struct ProfilesView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
    @StateObject private var store = ProfileStore()
    @State private var newProfileName = ""
    @State private var showNamePrompt = false

    var body: some View {
        Form {
            Section {
                if store.profiles.isEmpty {
                    Text("No saved profiles yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.profiles) { profile in
                        Button {
                            apply(profile)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).foregroundColor(.primary)
                                Text(summary(for: profile))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(server.isRunning)
                    }
                    .onDelete { indexSet in
                        for index in indexSet { store.delete(store.profiles[index]) }
                    }
                }
            } header: {
                Text("Saved Profiles")
            } footer: {
                Text(server.isRunning ? "Stop the proxy to switch profiles." : "Tap a profile to apply its settings.")
            }

            Section {
                Button("Save Current Settings as New Profile…") { showNamePrompt = true }
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Profile Name", isPresented: $showNamePrompt) {
            TextField("Name", text: $newProfileName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) { newProfileName = "" }
        }
    }

    private func summary(for profile: ProxyProfile) -> String {
        var parts = ["port \(profile.primaryPort)"]
        if !profile.additionalListeners.isEmpty {
            parts.append("+\(profile.additionalListeners.count) listener\(profile.additionalListeners.count == 1 ? "" : "s")")
        }
        if profile.dohEnabled { parts.append("DoH on") }
        if profile.egressInterface != .automatic { parts.append("out: \(profile.egressInterface.label)") }
        if profile.backgroundKeepAliveRequested { parts.append("keep-alive") }
        return parts.joined(separator: " · ")
    }

    private func saveCurrent() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProfileName = ""
        guard !name.isEmpty else { return }
        let profile = ProxyProfile(
            name: name,
            primaryPort: server.port,
            additionalListeners: server.additionalListeners,
            dohEnabled: UserDefaults.standard.bool(forKey: "doh.enabled"),
            dohUpstreamURL: UserDefaults.standard.string(forKey: "doh.upstreamURL") ?? "",
            backgroundKeepAliveRequested: keeper.isKeepingAlive,
            egressInterface: EgressInterface.stored
        )
        store.save(profile)
    }

    private func apply(_ profile: ProxyProfile) {
        guard !server.isRunning else { return }
        server.port = profile.primaryPort
        server.additionalListeners = profile.additionalListeners
        UserDefaults.standard.set(profile.dohEnabled, forKey: "doh.enabled")
        UserDefaults.standard.set(profile.dohUpstreamURL, forKey: "doh.upstreamURL")
        UserDefaults.standard.set(profile.egressInterface.rawValue, forKey: EgressInterface.defaultsKey)
        if profile.backgroundKeepAliveRequested, keeper.authorizationStatus == .authorizedAlways {
            keeper.start()
        } else if !profile.backgroundKeepAliveRequested {
            keeper.stop()
        }
    }
}
