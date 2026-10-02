import SwiftUI
import ClerkKitUI

struct WelcomeView: View {
    @State private var showAuth = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label("E INK", systemImage: "rectangle.inset.filled")
                    .font(.caption.weight(.bold)).tracking(3)
                    .foregroundStyle(InkTheme.accent)
                VStack(alignment: .leading, spacing: 10) {
                    Text("A little less screen.\nA little more home.")
                        .font(.system(.largeTitle, design: .serif)).fontWeight(.medium)
                    Text("Your home display, in your hands.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        Image(systemName: "sun.max").font(.largeTitle)
                        Spacer()
                        Image(systemName: "bolt").font(.largeTitle)
                    }
                    Rectangle().frame(height: 1).opacity(0.2)
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").font(.title2)
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().frame(width: 136, height: 5)
                            Capsule().frame(width: 86, height: 5).opacity(0.25)
                        }
                        Spacer()
                    }
                    Text("A QUIETER WAY TO STAY IN THE KNOW")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                }
                .padding(30).foregroundStyle(Color.black.opacity(0.8))
                .background(Color(red: 0.95, green: 0.95, blue: 0.91))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(14).background(Color(red: 0.23, green: 0.27, blue: 0.26))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .rotationEffect(.degrees(-3)).padding(.vertical, 8)
                .accessibilityLabel("Illustration of an e-ink home display")
                VStack(alignment: .leading, spacing: 17) {
                    feature("Make it yours", "Choose your sources and arrange your display.", "square.grid.2x2")
                    feature("Send it in a tap", "Update a nearby display over Bluetooth.", "radiowaves.left.and.right")
                    feature("Keep the same account", "Your saved settings stay in sync with the web app.", "arrow.triangle.2.circlepath")
                }
                Button { showAuth = true } label: {
                    HStack { Text("Sign in to your display"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.headline).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Connects to \(AppConfiguration.serverURL.host ?? "your server")")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }.padding(28).frame(maxWidth: 560)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showAuth) { AuthView() }
    }

    private func feature(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(InkTheme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
