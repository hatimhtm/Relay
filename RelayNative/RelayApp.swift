import SwiftUI
import AppKit
import Translation

@main
struct RelayApp: App {
    @StateObject private var store = RelayStore.shared
    @StateObject private var lock = AppLock.shared
    @StateObject private var updater = UpdaterModel.shared   // starts background update checks

    var body: some Scene {
        // Single window (not WindowGroup) so closing + reopening reuses the same
        // window and doesn't re-spawn the backend.
        Window("Relay", id: "main") {
            ContentView()
                .environmentObject(store)
                .background(GlassWindowBackground().ignoresSafeArea())  // glass fills under the title bar too
                .task { store.start() }
                .task { lock.lockAtLaunchIfNeeded() }
                .frame(minWidth: 820, minHeight: 560)
                // The lock screen covers everything (including the login view) while locked.
                .overlay { if lock.isLocked { LockView(lock: lock) } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
                Button("Lock Now") { lock.lockNow() }.keyboardShortcut("l", modifiers: .command)
            }
        }

        Settings { SettingsView().environmentObject(store) }

        // Always-there menu-bar companion: unread count + a quick jump panel.
        MenuBarExtra {
            MenuBarPanel(store: store).environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

extension View {
    /// Hidden on-device translation host. macOS 15+ only (Translation framework); a plain
    /// passthrough on Ventura, where translation features are simply unavailable.
    @ViewBuilder
    func relayTranslationHost(_ store: RelayStore) -> some View {
        if #available(macOS 15.0, *) {
            translationTask(store.translationConfigBox as? TranslationSession.Configuration) { session in
                await store.runTranslations(session)
            }
        } else {
            self
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: RelayStore
    @State private var selected: String?
    @State private var pasteMonitor: Any?
    @State private var showSwitcher = false

    var body: some View {
        Group {
            if store.needsLogin {
                LoginView()
            } else {
                main
            }
        }
    }

    private var main: some View {
        NavigationSplitView {
            SidebarView(selected: $selected)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            ZStack {
                if let id = selected, let thread = store.threads.first(where: { $0.id == id }) {
                    ThreadView(thread: thread)
                        .id(thread.id)   // fresh view per chat → always opens at the bottom, draft doesn't bleed over
                        // The container just crossfades quickly; the real motion is the
                        // per-bubble staggered cascade inside ThreadView (see CascadeIn).
                        .transition(.opacity)
                } else {
                    EmptyState().transition(.opacity)
                }
            }
            // NB: the detail does NOT ignore the top safe area — its content is transparent
            // over the window glass, so there's no band to fill (the hidden toolbar background
            // handles that), and the header overlay must respect the safe area to sit below
            // the titlebar instead of being clipped.
            .clipped()
        }
        .navigationTitle("")
        // Kill the unified toolbar's material band so the window is one continuous glass
        // surface; content bleeds under the traffic lights (see ignoresSafeArea on the columns).
        .hideWindowToolbarBackground()
        .sheet(isPresented: $showSwitcher) {
            QuickSwitcher(selected: $selected, isPresented: $showSwitcher)
                .environmentObject(store)
        }
        // Esc closes the open conversation and returns to the empty start page.
        .onExitCommand { if selected != nil { withAnimation(.smooth(duration: 0.2)) { selected = nil } } }
        // Re-lock when Relay loses focus (if the user enabled that).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            AppLock.shared.lockOnResignIfNeeded()
        }
        // Hidden host that performs on-device translation whenever the store requests it
        // (macOS 15+; a no-op on Ventura where the Translation framework doesn't exist).
        .relayTranslationHost(store)
        // An App Intent (Siri/Shortcuts) asked to open a conversation → select it.
        .onChangeCompat(of: store.pendingOpen) { _, id in
            guard let id else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = id }
            store.pendingOpen = nil
        }
        .onChangeCompat(of: selected) { _, new in
            store.activeThread = new
            store.stagedImages = []   // don't carry staged pictures between chats
            if let new {
                store.markRead(new)
                store.refreshThread(new)   // pull anything missed while closed
            }
        }
        .onAppear(perform: installPasteMonitor)
        // Keyboard navigation: ⌘1–9 jump to the Nth chat, ⌘↑/↓ move between chats.
        // Invisible buttons (opacity 0) still fire their keyboard shortcuts.
        .background {
            ZStack {
                ForEach(1...9, id: \.self) { i in
                    Button("") { jumpToChat(i - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                }
                Button("") { moveSelection(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("") { moveSelection(1) }.keyboardShortcut(.downArrow, modifiers: .command)
            }
            .opacity(0)
        }
    }

    private func jumpToChat(_ index: Int) {
        let list = store.navigationOrder
        guard index >= 0, index < list.count else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = list[index].id }
    }
    private func moveSelection(_ delta: Int) {
        let list = store.navigationOrder
        guard !list.isEmpty else { return }
        let i = selected.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(list.count - 1, i + delta < 0 ? 0 : i + delta))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = list[next].id }
    }

    // App-wide Cmd+V: if the clipboard holds an image, send it to the open chat and
    // swallow the key event; otherwise let it through so normal text paste still works.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        let selection = $selected
        let switcher = $showSwitcher
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let cmd = event.modifierFlags.contains(.command)
            // Cmd+K → toggle the quick switcher.
            if cmd, event.charactersIgnoringModifiers?.lowercased() == "k" {
                switcher.wrappedValue.toggle()
                return nil
            }
            // Esc → close the switcher first, otherwise back to the empty start page.
            if event.keyCode == 53 {
                if switcher.wrappedValue { switcher.wrappedValue = false; return nil }
                if selection.wrappedValue != nil {
                    withAnimation(.smooth(duration: 0.2)) { selection.wrappedValue = nil }
                    return nil
                }
                return event
            }
            // Cmd+V with an image on the clipboard → stage it (only when not switching).
            if cmd, !switcher.wrappedValue,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               store.pasteImageIfAvailable() {
                return nil   // consumed an image
            }
            return event
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject var store: RelayStore
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Relay").font(.largeTitle.weight(.semibold))
            Text(store.status).font(.callout).foregroundStyle(.secondary)
            if !store.connected {
                Button("Sign in again") { store.requestRelogin() }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Glass window background (blurs the desktop behind the whole window)

struct GlassWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        DispatchQueue.main.async {
            if let win = view.window {
                win.isOpaque = false
                win.backgroundColor = .clear
                // Make the window one continuous surface: content flows under the
                // title bar, no separate-colored navbar band, no hairline separator.
                win.styleMask.insert(.fullSizeContentView)
                win.titleVisibility = .hidden
                win.titlebarAppearsTransparent = true
                win.titlebarSeparatorStyle = .none
                win.isMovableByWindowBackground = false // only the title bar drags
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
