import SwiftUI

struct DevicesView: View {
    let api: APIClient
    @State private var devices: [Device] = []
    @State private var loading = true
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try again") { Task { await load() } }
                }
            }
            if loading && devices.isEmpty {
                ProgressView("Loading displays…")
            } else if devices.isEmpty && error == nil {
                ContentUnavailableView {
                    Label("Your displays", systemImage: "rectangle.connected.to.line.below")
                } description: {
                    Text("Register your first e-ink display to manage its screen and Wi-Fi delivery.")
                } actions: {
                    Button("Add display") { adding = true }.buttonStyle(.borderedProminent)
                }
            }
            ForEach(devices) { device in
                NavigationLink {
                    DeviceDetailView(api: api, device: device) { Task { await load() } }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.inset.filled")
                            .font(.title2).foregroundStyle(.teal)
                            .frame(width: 38, height: 44)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.device_name).font(.headline)
                            Text(device.ble_name ?? device.device_id)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let date = device.last_seen_at {
                                Text("Last seen \(displayDate(date))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Displays")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add display", systemImage: "plus") { adding = true }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $adding) {
            AddDeviceView(api: api) { device in devices.append(device) }
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do {
            devices = try await api.devices()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct AddDeviceView: View {
    let api: APIClient
    let onAdded: (Device) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bleName = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name)
                    TextField("Hardware name, e.g. OD-ABC123", text: $bleName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Enter the hardware name shown by your device if it is already configured. Leave it empty to register a new display with an assigned ID. Registration does not configure Wi-Fi or pair Bluetooth.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("Add display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    @MainActor private func add() async {
        busy = true
        defer { busy = false }
        do {
            let hardware = bleName.trimmingCharacters(in: .whitespacesAndNewlines)
            let device = try await api.addDevice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), bleName: hardware.isEmpty ? nil : hardware)
            onAdded(device)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct DeviceDetailView: View {
    let api: APIClient
    @State var device: Device
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: DeviceDeliveryStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var renamed = ""
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var confirmToken = false
    @State private var confirmRevoke = false
    @State private var token: DeliveryToken?

    var body: some View {
        Form {
            Section {
                LabeledContent("Hardware", value: device.ble_name ?? device.device_id)
                NavigationLink("Display settings") {
                    SettingsView(api: api, deviceID: device.id, deviceName: device.device_name)
                }
                Button("Rename display") {
                    renamed = device.device_name
                    renaming = true
                }
            }
            Section {
                if let status {
                    LabeledContent("Delivery", value: status.configured ? "Token configured" : "Not configured")
                    LabeledContent("Last check-in", value: displayDate(status.lastSeenAt))
                    LabeledContent("Firmware", value: status.firmwareVersion ?? device.firmware_version ?? "Not reported")
                    if let battery = status.batteryPercent {
                        LabeledContent("Battery", value: "\(battery)%")
                    }
                    if let rssi = status.rssi {
                        LabeledContent("Wi-Fi signal", value: "\(rssi) dBm")
                    }
                    if status.refreshRequestId != nil {
                        LabeledContent("Refresh", value: status.refreshPending ? "Waiting for device" : "Applied by device")
                        LabeledContent("Requested", value: displayDate(status.refreshRequestedAt))
                    }
                    if status.refreshAppliedAt != nil {
                        LabeledContent("Last applied", value: displayDate(status.refreshAppliedAt))
                    }
                    Button("Request Wi-Fi refresh", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await requestRefresh() }
                    }.disabled(!status.configured || status.refreshPending)
                } else {
                    if error == nil { ProgressView("Checking delivery…") }
                }
                Button("Check status", systemImage: "arrow.clockwise") { Task { await load() } }
            } header: {
                Text("Wi-Fi delivery")
            } footer: {
                Text("A refresh waits for the display’s next Wi-Fi check-in and may override quiet hours. The request does not wake a sleeping ESP32. Applied status confirms the device’s report.")
            }
            Section {
                Button(status?.configured == true ? "Rotate delivery token" : "Create delivery token", systemImage: "key") {
                    confirmToken = true
                }.disabled(status == nil)
                if status?.configured == true {
                    Button("Revoke delivery token", role: .destructive) { confirmRevoke = true }
                }
            } header: {
                Text("Device access")
            } footer: {
                Text("Install the delivery token using your device’s firmware setup. Tokens are shown once; rotating or revoking a token disconnects the currently configured device until its setup is updated.")
            }
            if let notice {
                Section { Label(notice, systemImage: "info.circle").foregroundStyle(.secondary) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Remove display", role: .destructive) { confirmDelete = true }
            }
        }
        .disabled(busy)
        .navigationTitle(device.device_name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Rename display", isPresented: $renaming) {
            TextField("Display name", text: $renamed)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
                .disabled(renamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Remove \(device.device_name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove display", role: .destructive) { Task { await remove() } }
        } message: {
            Text("This removes the display from your account and its server delivery setup. It does not erase the firmware.")
        }
        .confirmationDialog(status?.configured == true ? "Rotate delivery token?" : "Create delivery token?", isPresented: $confirmToken, titleVisibility: .visible) {
            Button(status?.configured == true ? "Rotate token" : "Create token") { Task { await createToken() } }
        } message: {
            Text("Save the new token when it appears. Any previous delivery token stops working immediately.")
        }
        .confirmationDialog("Revoke delivery token?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke token", role: .destructive) { Task { await revokeToken() } }
        } message: {
            Text("The display will no longer be able to retrieve new screens over Wi-Fi.")
        }
        .sheet(item: $token, onDismiss: { token = nil }) { item in
            DeliveryTokenView(token: item.token)
        }
    }

    @MainActor private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            status = try await api.deliveryStatus(deviceID: device.id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func rename() async {
        busy = true
        defer { busy = false }
        do {
            device = try await api.renameDevice(id: device.id, name: renamed.trimmingCharacters(in: .whitespacesAndNewlines))
            error = nil
            onChanged()
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func remove() async {
        busy = true
        defer { busy = false }
        do {
            try await api.deleteDevice(id: device.id)
            onChanged()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func requestRefresh() async {
        busy = true
        defer { busy = false }
        do {
            status = try await api.requestRefresh(deviceID: device.id)
            notice = "Refresh queued. Check status after the device’s next Wi-Fi check-in."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func createToken() async {
        busy = true
        defer { busy = false }
        do {
            token = DeliveryToken(token: try await api.createDeliveryToken(deviceID: device.id))
            notice = "A new token was created. Update the device’s firmware configuration."
            error = nil
            status = try await api.deliveryStatus(deviceID: device.id)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func revokeToken() async {
        busy = true
        defer { busy = false }
        do {
            try await api.revokeDeliveryToken(deviceID: device.id)
            token = nil
            notice = "Delivery token revoked."
            error = nil
            status = try await api.deliveryStatus(deviceID: device.id)
        } catch { self.error = error.localizedDescription }
    }
}

private struct DeliveryToken: Identifiable {
    let id = UUID()
    let token: String
}

private struct DeliveryTokenView: View {
    let token: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Keep this token private", systemImage: "lock.shield")
                    Text("The token grants this display access to its screen content. It will not be available again after you close this sheet.")
                }
                Section {
                    if revealed && scenePhase == .active {
                        Text(token).font(.footnote.monospaced()).textSelection(.enabled).privacySensitive()
                    } else {
                        Text("••••••••••••••••••••••••").font(.body.monospaced())
                    }
                    Button(revealed ? "Hide token" : "Reveal token") { revealed.toggle() }
                    ShareLink(item: token) { Label("Share token securely", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("Delivery token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
        }
    }
}

private func displayDate(_ value: String?) -> String {
    guard let value else { return "Not reported" }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let precise = parser.date(from: value)
    parser.formatOptions = [.withInternetDateTime]
    guard let date = precise ?? parser.date(from: value) else { return "Not reported" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

