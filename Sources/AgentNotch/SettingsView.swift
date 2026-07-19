import SwiftUI

/// Placeholder scaffold for the app's settings window (SwiftUI `Settings`
/// scene). The actual controls (sliders etc. bound to `AppSettings`) are
/// added separately; this only establishes the window and section layout.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AgentNotch Settings")
                .font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            Text("General")
                .font(.headline)
            Text("Settings controls will go here.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}
