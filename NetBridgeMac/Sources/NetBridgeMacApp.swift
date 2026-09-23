import SwiftUI

@main
struct NetBridgeMacApp: App {
    @StateObject private var model = MacClientModel()

    var body: some Scene {
        // A single `Window` (not `WindowGroup`) so the menu bar item can reopen *the* window by id. With the
        // MenuBarExtra below, closing it leaves the app — and the tunnel status icon — running.
        Window("NetBridge", id: "main") {
            MacRootView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 620)
        .commands {
            CommandMenu("Connection") {
                Button(model.isConnectedOrConnecting ? "Disconnect" : "Connect") {
                    model.connectOrDisconnect()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canConnect)
            }
        }

        MenuBarExtra {
            MacMenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
        }
    }

    private var menuBarSymbol: String {
        if case .unreachable = model.proxyHealth { return "exclamationmark.shield" }
        return model.tunnel.status == .connected ? "shield.lefthalf.filled" : "shield.slash"
    }
}
