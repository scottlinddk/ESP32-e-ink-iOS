import SwiftUI
import ClerkKit
import ClerkKitUI

@main
@MainActor
struct EInkApp: App {
    private let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Clerk.configure(publishableKey: AppConfiguration.publishableKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            if isTesting {
                Color.clear
            } else {
                RootView()
                    .environment(Clerk.shared)
                    .tint(InkTheme.accent)
            }
        }
    }
}

enum AppConfiguration {
    static let serverURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "EInkServerURL") as? String ?? "https://esp32.scottlind.dk")!
    static let publishableKey = Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String ?? ""
}

enum InkTheme {
    static let accent = Color(red: 0.24, green: 0.43, blue: 0.40)
}

struct RootView: View {
    @Environment(Clerk.self) private var clerk
    @State private var callbackError: String?

    var body: some View {
        Group {
            if clerk.isAuthFlowComplete, let user = clerk.user, let session = clerk.session {
                SignedInView(userID: user.id, sessionID: session.id).id(session.id)
            } else {
                WelcomeView()
            }
        }
        .onOpenURL { url in
            Task {
                do { try await clerk.handle(url) }
                catch { callbackError = error.localizedDescription }
            }
        }
        .alert("Sign-in could not finish", isPresented: Binding(get: { callbackError != nil }, set: { if !$0 { callbackError = nil } })) {
            Button("OK", role: .cancel) { callbackError = nil }
        } message: { Text(callbackError ?? "") }
    }
}

private struct SignedInView: View {
    @State private var api: APIClient

    init(userID: String, sessionID: String) {
        _api = State(initialValue: APIClient(baseURL: AppConfiguration.serverURL) { @MainActor in
            let clerk = Clerk.shared
            guard clerk.isAuthFlowComplete, clerk.user?.id == userID,
                  let session = clerk.session, session.id == sessionID else { throw APIError.missingToken }
            // Old tasks must never acquire the next account's bearer after an account switch.
            guard let token = try await session.getToken(), clerk.isAuthFlowComplete,
                  clerk.user?.id == userID, clerk.session?.id == sessionID else { throw APIError.missingToken }
            try Task.checkCancellation()
            return token
        })
    }

    var body: some View {
        TabView {
            DashboardView(api: api)
                .tabItem { Label("Display", systemImage: "rectangle.inset.filled") }
            NavigationStack { DevicesView(api: api) }
                .tabItem { Label("Devices", systemImage: "sensor.tag.radiowaves.forward") }
            NavigationStack { SettingsView(api: api) }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
    }
}

private struct AccountView: View {
    @Environment(Clerk.self) private var clerk
    @State private var showProfile = false
    @State private var signingOut = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Your account") {
                    Button("Manage account", systemImage: "person.crop.circle") { showProfile = true }
                    Button("Sign out", role: .destructive) {
                        guard let sessionID = clerk.session?.id else { return }
                        signingOut = true
                        Task {
                            defer { signingOut = false }
                            do { try await clerk.auth.signOut(sessionId: sessionID) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(signingOut)
                }
                Section("Connected service") {
                    LabeledContent("Server", value: AppConfiguration.serverURL.host ?? "")
                    Link("Open web dashboard", destination: AppConfiguration.serverURL)
                    Link("App source and setup", destination: URL(string: "https://github.com/scottlinddk/ESP32-e-ink-iOS")!)
                }
                Section {
                    Text("Bluetooth updates run while this app is open. Wi-Fi displays fetch their saved layouts independently of your iPhone.")
                    Text("USB firmware installation requires desktop Chrome or Edge. Use the web dashboard for firmware, advanced integrations, and schedules.")
                }.font(.footnote).foregroundStyle(.secondary)
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Account")
            .sheet(isPresented: $showProfile) { UserProfileView() }
        }
    }
}
