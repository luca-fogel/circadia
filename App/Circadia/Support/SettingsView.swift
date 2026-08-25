import SwiftUI

#if os(macOS)
/// macOS Settings window. Deliberately thin: everything that matters is per-trip.
struct SettingsView: View {
    @Environment(NotificationScheduler.self) private var scheduler
    @State private var pending = 0

    var body: some View {
        Form {
            Section("Reminders") {
                LabeledContent("Permission", value: label)
                LabeledContent("Pending", value: "\(pending)")
                Button("Cancel all reminders") { scheduler.cancelAll() }
            }
            Section {
                AboutTheScience()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .task {
            await scheduler.refreshAuthorisation()
            pending = await scheduler.pendingCount()
        }
    }

    private var label: String {
        switch scheduler.authorisation {
        case .granted: "Allowed"
        case .provisional: "Provisional"
        case .denied: "Denied"
        case .unknown: "Not asked yet"
        }
    }
}
#endif
