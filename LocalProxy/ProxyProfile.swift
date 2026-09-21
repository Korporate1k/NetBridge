import Foundation

/// A saved combination of listener/DoH/keep-alive settings, so a user can
/// switch between a few setups without re-entering them. Persisted to
/// `Application Support/profiles.json`, following the same `Codable`
/// load/save pattern `DeviceRegistry` uses for `devices.json` — simpler here
/// since profiles are only ever touched from the main thread (Settings UI).
struct ProxyProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var primaryPort: Int
    var additionalListeners: [ListenerConfig]
    var dohEnabled: Bool
    var dohUpstreamURL: String
    var backgroundKeepAliveRequested: Bool
    var egressInterface: EgressInterface = .automatic

    private enum CodingKeys: String, CodingKey {
        case id, name, primaryPort, additionalListeners, dohEnabled, dohUpstreamURL, backgroundKeepAliveRequested, egressInterface
    }
}

extension ProxyProfile {
    /// Profiles saved before `egressInterface` existed have no such key; decode them as Automatic instead of failing the
    /// whole `profiles.json`. (In an extension so the memberwise init stays available.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        primaryPort = try c.decode(Int.self, forKey: .primaryPort)
        additionalListeners = try c.decode([ListenerConfig].self, forKey: .additionalListeners)
        dohEnabled = try c.decode(Bool.self, forKey: .dohEnabled)
        dohUpstreamURL = try c.decode(String.self, forKey: .dohUpstreamURL)
        backgroundKeepAliveRequested = try c.decode(Bool.self, forKey: .backgroundKeepAliveRequested)
        egressInterface = try c.decodeIfPresent(EgressInterface.self, forKey: .egressInterface) ?? .automatic
    }
}

final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ProxyProfile] = []
    private let fileURL: URL?

    init() {
        fileURL = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("profiles.json")
        load()
    }

    func save(_ profile: ProxyProfile) {
        profiles.append(profile)
        persist()
    }

    func delete(_ profile: ProxyProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    private func load() {
        guard let fileURL = fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            profiles = try JSONDecoder().decode([ProxyProfile].self, from: data)
        } catch {
            DebugLog.important("profiles", "load failed \(ErrorDescription.describe(error))")
        }
    }

    private func persist() {
        guard let fileURL = fileURL else { return }
        do {
            try JSONEncoder().encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            DebugLog.important("profiles", "save failed \(ErrorDescription.describe(error))")
        }
    }
}
