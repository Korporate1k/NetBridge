import SwiftUI
import ServiceManagement

/// The app's Settings window (⌘,). The login item state lives in the system
/// (`SMAppService`), not in UserDefaults, so it's re-read rather than stored.
struct MacSettingsView: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var needsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { openAtLogin },
                    set: { setOpenAtLogin($0) }
                ))
                if needsApproval {
                    Text("Allow NetBridge in System Settings → General → Login Items.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            } footer: {
                Text("Starts NetBridge in the menu bar when you log in. Closing the window keeps it running there.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
    }

    private func setOpenAtLogin(_ on: Bool) {
        errorMessage = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Couldn't \(on ? "enable" : "disable") Open at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        needsApproval = status == .requiresApproval
    }
}
