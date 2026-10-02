import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    let api: APIClient
    @State private var devices: [Device] = []
    @State private var selectedDeviceID = ""
    @State private var preview: PreviewImage?
    @State private var loading = false
    @State private var previewRequestID: UUID?
    @State private var error: String?
    @State private var showBluetooth = false
    @State private var exportImage = false

    private var deviceID: String? { selectedDeviceID.isEmpty ? nil : selectedDeviceID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A quiet view of your day.")
                            .font(.system(.title2, design: .serif))
                        Text("Preview your saved layout, then send it to your display.")
                            .foregroundStyle(.secondary).font(.subheadline)
                    }
                    Picker("Layout for", selection: $selectedDeviceID) {
                        Text("Account default").tag("")
                        ForEach(devices) { Text($0.device_name).tag($0.id) }
                    }.pickerStyle(.menu)
                    previewCard
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.red)
                            .accessibilityIdentifier("preview-error")
                    }
                    VStack(spacing: 12) {
                        Button { showBluetooth = true } label: {
                            Label("Send over Bluetooth", systemImage: "radiowaves.left.and.right")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(loading || preview == nil)
                        HStack {
                            Button { Task { await refresh() } } label: {
                                Label("Refresh preview", systemImage: "arrow.clockwise")
                            }.disabled(loading)
                            Spacer()
                            Button { exportImage = true } label: {
                                Label("Save BMP", systemImage: "square.and.arrow.up")
                            }.disabled(preview == nil || loading)
                        }.font(.subheadline).buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Two ways to update", systemImage: "info.circle").font(.headline)
                        Text("Bluetooth sends a fresh image to a nearby display while the app stays open.")
                        Text("For a Wi-Fi display, open Devices and request an update. It will apply when the display next connects.")
                    }.font(.subheadline).foregroundStyle(.secondary)
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 18))
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Your display")
            .refreshable { await refresh() }
            .task {
                do {
                    let loaded = try await api.devices()
                    try Task.checkCancellation()
                    devices = loaded
                    if !selectedDeviceID.isEmpty, !loaded.contains(where: { $0.id == selectedDeviceID }) {
                        selectedDeviceID = ""
                    }
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .task(id: selectedDeviceID) { await refresh() }
            .sheet(isPresented: $showBluetooth) { BluetoothPushView(api: api, deviceID: deviceID) }
            .fileExporter(isPresented: $exportImage, document: BMPDocument(data: preview?.data ?? Data()), contentType: .bmp, defaultFilename: "eink-display") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("SAVED DISPLAY", systemImage: "rectangle.inset.filled")
                    .font(.caption.weight(.semibold)).tracking(1)
                Spacer()
                if loading { ProgressView() }
            }.foregroundStyle(.secondary)
            if let preview, let bitmap = UIImage(data: preview.data) {
                Image(uiImage: bitmap).resizable().interpolation(.none).scaledToFit()
                    .padding(12).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Rendered display preview for \(preview.metadata.layoutName)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(preview.metadata.layoutName).font(.headline)
                    Text("\(preview.metadata.profile.width) × \(preview.metadata.profile.height) · \(preview.metadata.profile.rotation)°")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if preview.metadata.quiet {
                        Label("Quiet hours are active", systemImage: "moon").font(.caption)
                    }
                    Text("This is the server preview. The physical display changes after an update is confirmed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label(loading ? "Rendering your display" : "No preview yet", systemImage: "rectangle.dashed")
                } description: {
                    Text(loading ? "Loading your saved sources and layout." : "Refresh to load the display from your account.")
                }
            }
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    @MainActor private func refresh() async {
        let requestedID = deviceID
        let requestID = UUID()
        previewRequestID = requestID
        loading = true
        defer { if previewRequestID == requestID { loading = false } }
        error = nil
        preview = nil
        do {
            let image = try await api.previewBMP(deviceID: requestedID)
            try Task.checkCancellation()
            guard previewRequestID == requestID, requestedID == deviceID else { return }
            guard UIImage(data: image.data) != nil else {
                throw NSError(domain: "EInk", code: 1, userInfo: [NSLocalizedDescriptionKey: "The server returned an unreadable display image."])
            }
            preview = image
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, previewRequestID == requestID, requestedID == deviceID else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct BMPDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.bmp] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BluetoothPushView: View {
    let api: APIClient
    let deviceID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bluetooth = BluetoothController()
    @State private var transfer: Task<Void, Never>?
    @State private var loadingImage = false
    @State private var error: String?
    @State private var completed = false

    private var busy: Bool { loadingImage || bluetooth.isBusy }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(completed ? "Display updated" : "Send to a nearby display", systemImage: completed ? "checkmark.circle.fill" : "radiowaves.left.and.right")
                        .font(.headline).foregroundStyle(completed ? InkTheme.accent : .primary)
                    Text("Turn on your display and keep this app open until its refresh is confirmed.")
                        .foregroundStyle(.secondary)
                    if loadingImage { ProgressView("Loading a fresh image…") }
                    else if bluetooth.isBusy { ProgressView(value: bluetooth.progress) }
                    Text(bluetooth.status).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                if !completed {
                    Section("Nearby displays") {
                        ForEach(bluetooth.devices) { device in
                            Button { send(to: device) } label: {
                                HStack {
                                    Label(device.name, systemImage: "rectangle.inset.filled")
                                    Spacer()
                                    Text("\(device.rssi) dBm").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }.disabled(busy)
                        }
                        if bluetooth.devices.isEmpty {
                            Text(bluetooth.isScanning ? "Looking for EInk and OpenDisplay devices…" : "No nearby displays found.")
                                .foregroundStyle(.secondary)
                        }
                        Button(bluetooth.isScanning ? "Stop scan" : "Scan again") {
                            if bluetooth.isScanning { bluetooth.stopScan() }
                            else { error = nil; bluetooth.startScan() }
                        }.disabled(busy)
                    }
                }
                Section {
                    Text("Bundled EInk firmware supports the 250 × 122 panel. OpenDisplay devices must use a compatible monochrome profile and byte-aligned width.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(completed ? "Done" : "Cancel") { cancel(); dismiss() }
                }
            }
            .task { bluetooth.startScan() }
            .onDisappear { cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancel(); error = "Update stopped because the app went into the background. Keep the app open and try again." }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func send(to device: DiscoveredDisplay) {
        error = nil
        loadingImage = true
        bluetooth.stopScan()
        transfer = Task { @MainActor in
            defer { loadingImage = false; transfer = nil }
            do {
                let frame = try await api.previewRaw(deviceID: deviceID)
                try Task.checkCancellation()
                loadingImage = false
                try await bluetooth.push(pixels: frame.pixels, profile: frame.profile, device: device)
                try Task.checkCancellation()
                completed = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
                self.error = "Update cancelled. Refresh was not confirmed."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func cancel() { transfer?.cancel(); bluetooth.cancel(); bluetooth.stopScan() }
}
