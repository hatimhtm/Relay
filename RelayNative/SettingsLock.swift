import SwiftUI
import LocalAuthentication

// MARK: - App lock (Touch ID / password)

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var isLocked = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: "appLockEnabled") }

    /// Lock at launch if the user enabled it.
    func lockAtLaunchIfNeeded() {
        if enabled { isLocked = true; authenticate() }
    }
    /// Re-lock when Relay loses focus (only if both toggles are on).
    func lockOnResignIfNeeded() {
        if enabled, UserDefaults.standard.bool(forKey: "appLockOnInactive") { isLocked = true }
    }
    /// Manual ⌘L.
    func lockNow() { if enabled { isLocked = true } }

    func authenticate() {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Password"
        var err: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication   // Touch ID, with password fallback
        guard ctx.canEvaluatePolicy(policy, error: &err) else {
            isLocked = false   // no biometrics/password available → never lock the user out
            return
        }
        ctx.evaluatePolicy(policy, localizedReason: "Unlock Relay") { ok, _ in
            Task { @MainActor in if ok { withAnimation(.easeOut(duration: 0.25)) { self.isLocked = false } } }
        }
    }
}

/// Full-cover lock screen shown above everything while locked.
struct LockView: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Relay is locked").font(.title3.weight(.semibold))
                Button { lock.authenticate() } label: {
                    Label("Unlock", systemImage: "touchid")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460, height: 300)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showSeenIndicators") private var showSeen = true
    @AppStorage("enterToSend") private var enterToSend = true
    var body: some View {
        Form {
            Toggle("Show seen / delivery indicators in the sidebar", isOn: $showSeen)
            Toggle("Press Return to send (Shift+Return for a new line)", isOn: $enterToSend)
            Section("Updates") {
                LabeledContent("Version", value: Self.versionString)
                Button("Check for Updates…") { UpdaterModel.shared.checkForUpdates() }
                Text("Relay updates itself automatically. You can also check manually here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private static var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

private struct NotificationSettings: View {
    @AppStorage("notificationsEnabled") private var enabled = true
    @AppStorage("notificationSound") private var sound = true
    var body: some View {
        Form {
            Toggle("Show notifications for new messages", isOn: $enabled)
            Toggle("Play a sound", isOn: $sound).disabled(!enabled)
            Text("Reply right from the notification banner. (Set Relay to “Alerts” in System Settings → Notifications so the reply field appears.)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct PrivacySettings: View {
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @AppStorage("appLockOnInactive") private var lockOnInactive = false
    var body: some View {
        Form {
            Toggle("Require Touch ID / password to unlock Relay", isOn: $lockEnabled)
            Toggle("Also lock whenever Relay loses focus", isOn: $lockOnInactive).disabled(!lockEnabled)
            Text("When on, Relay locks at launch (and on ⌘L). Uses Touch ID with your login password as a fallback.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var store: RelayStore
    @State private var confirmSignOut = false
    var body: some View {
        Form {
            LabeledContent("Status", value: store.connected ? "Connected" : "Offline")
            if !store.selfID.isEmpty {
                LabeledContent("Account", value: store.name(for: store.selfID))
            }
            Button("Sign Out…", role: .destructive) { confirmSignOut = true }
        }
        .padding(20)
        .confirmationDialog("Sign out of Relay?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { store.signOut() }
        } message: {
            Text("You'll need to sign in again to use Relay.")
        }
    }
}
