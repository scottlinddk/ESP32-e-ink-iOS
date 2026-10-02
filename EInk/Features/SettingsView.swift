import SwiftUI

struct SettingsView: View {
    let api: APIClient
    var deviceID: String? = nil
    var deviceName: String? = nil
    @State private var original: Preferences = [:]
    @State private var draft: Preferences = [:]
    @State private var inherited = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    private var patch: Preferences { draft.filter { original[$0.key] != $0.value } }

    var body: some View {
        Form {
            if !loaded {
                if busy { ProgressView("Loading settings…") }
                else { Button("Load settings") { Task { await load() } } }
            } else {
                if let deviceName {
                    Section {
                        LabeledContent("Display", value: deviceName)
                        Text(inherited ? "This display currently uses the account defaults. Saving creates its own display settings." : "These display settings apply to this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                presentationSection
                if deviceID == nil {
                    sourcesSections
                    Section {
                        NavigationLink("Service credentials") { CredentialsView(api: api) }
                    } footer: {
                        Text("Service credentials and content sources are shared by the displays in your account.")
                    }
                } else {
                    Section {
                        Text("Content sources and service credentials come from your account settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                if saved && patch.isEmpty {
                    Section { Label("Settings saved", systemImage: "checkmark.circle").foregroundStyle(.teal) }
                }
                if !patch.isEmpty {
                    Section { Text("You have unsaved changes.").foregroundStyle(.secondary) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(busy)
        .navigationTitle(deviceID == nil ? "Settings" : "Display settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if busy { ProgressView() }
                else { Button("Save") { Task { await save() } }.disabled(!loaded || patch.isEmpty) }
            }
        }
        .task { if !loaded { await load() } }
    }

    private var presentationSection: some View {
        Section {
            TextField("Time zone", text: text("display_timezone", default: "Europe/Copenhagen"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Stepper("Refresh every \(number("refresh_interval_minutes", default: 30)) minutes", value: integer("refresh_interval_minutes", default: 30), in: 1...1440)
            NavigationLink("Panel size & orientation") {
                PanelSettingsView(profile: Binding(get: { draft["display_profile"] }, set: { draft["display_profile"] = $0 }))
            }
            NavigationLink("Arrange widgets") {
                LayoutSettingsView(value: draft["layout"]) { draft["layout"] = $0 }
            }
            if draft["display_schedule"]?.objectValue?["enabled"]?.boolValue == true {
                Label("A slideshow is active. Manage its pages and schedule in the web dashboard.", systemImage: "rectangle.stack")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if draft["active_layout_id"]?.stringValue != nil {
                Label("A saved layout is selected. Change the active layout in the web dashboard to display changes to this base layout.", systemImage: "rectangle.stack")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Presentation")
        } footer: {
            Text("Time zones use names such as Europe/Copenhagen. Screens update on the display’s next connection.")
        }
    }

    @ViewBuilder private var sourcesSections: some View {
        Section("Electricity") {
            Toggle("Show electricity prices", isOn: toggle("show_energy_price", default: true))
            Picker("Price area", selection: text("energy_price_location", default: "DK1")) {
                Text("DK1 · West Denmark").tag("DK1")
                Text("DK2 · East Denmark").tag("DK2")
            }
        }
        Section {
            Toggle("Show weather", isOn: toggle("show_weather", default: true))
            TextField("Latitude, longitude", text: text("weather_location", default: "55.3,10.4"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
            Text("Weather")
        } footer: {
            Text("Use coordinates such as 55.6761,12.5683. Add an OpenWeather API key in Service credentials.")
        }
        Section("News") {
            Toggle("Show news", isOn: toggle("show_news", default: true))
            Picker("Source", selection: text("news_source", default: "newsapi")) {
                Text("NewsAPI").tag("newsapi")
                Text("RSS feed").tag("rss")
            }
            if draft["news_source"]?.stringValue == "rss" {
                TextField("Public HTTPS feed URL", text: text("news_feed_url"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                Picker("Language", selection: text("news_language", default: "da")) {
                    Text("Danish").tag("da")
                    Text("English").tag("en")
                    Text("German").tag("de")
                    Text("Swedish").tag("sv")
                    Text("Norwegian").tag("no")
                    Text("Finnish").tag("fi")
                }
            }
            Stepper("Up to \(number("news_item_limit", default: 3)) headlines", value: integer("news_item_limit", default: 3), in: 1...10)
        }
        Section("Calendar") {
            Toggle("Show calendar", isOn: toggle("show_calendar"))
            TextField("Calendar time zone", text: text("calendar_timezone", default: "Europe/Copenhagen"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Stepper("Next \(number("calendar_days", default: 7)) days", value: integer("calendar_days", default: 7), in: 1...30)
            Stepper("Up to \(number("calendar_item_limit", default: 5)) events", value: integer("calendar_item_limit", default: 5), in: 1...10)
        }
        Section {
            Toggle("Show custom text", isOn: toggle("show_custom_text"))
            TextField("Text for your display", text: text("custom_text"), axis: .vertical).lineLimit(3...8)
        } header: { Text("Custom text") }
        Section {
            Toggle("Monta", isOn: toggle("show_monta"))
            Toggle("Zaptec", isOn: toggle("show_zaptec"))
            Toggle("Notion", isOn: toggle("show_notion"))
            Toggle("Custom image", isOn: toggle("show_custom_image"))
            Toggle("Sensor webhook", isOn: toggle("show_custom_webhook"))
        } header: {
            Text("Connected sources")
        } footer: {
            Text("Set up these integrations and images in the web dashboard. Add each enabled source to your widget layout to show it.")
        }
    }

    private func text(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { draft[key]?.stringValue ?? fallback }, set: { draft[key] = .string($0) })
    }
    private func toggle(_ key: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { draft[key]?.boolValue ?? fallback }, set: { draft[key] = .bool($0) })
    }
    private func number(_ key: String, default fallback: Int) -> Int { draft[key]?.intValue ?? fallback }
    private func integer(_ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { number(key, default: fallback) }, set: { draft[key] = .number(Double($0)) })
    }

    @MainActor private func load() async {
        busy = true
        defer { busy = false }
        do {
            let response = try await api.preferences(deviceID: deviceID)
            original = response.preferences
            draft = original
            inherited = response.inherited ?? false
            loaded = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func save() async {
        guard !patch.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let response = try await api.savePreferences(patch, deviceID: deviceID)
            original = response.preferences
            draft = original
            inherited = response.inherited ?? false
            saved = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct PanelSettingsView: View {
    @Binding var profile: JSONValue?

    private var fields: Preferences {
        profile?.objectValue ?? ["width": .number(250), "height": .number(122), "rotation": .number(0), "colorMode": .string("bw")]
    }

    var body: some View {
        Form {
            Section {
                Stepper("Width: \(fields["width"]?.intValue ?? 250) px", value: number("width", default: 250), in: 64...1600)
                Stepper("Height: \(fields["height"]?.intValue ?? 122) px", value: number("height", default: 122), in: 64...1600)
                Picker("Rotation", selection: number("rotation", default: 0)) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                LabeledContent("Color", value: "Black & white")
            } footer: {
                Text("Match the physical panel in your firmware. Maximum size is 1,920,000 pixels. Save your settings after making changes.")
            }
            if (fields["width"]?.intValue ?? 250) * (fields["height"]?.intValue ?? 122) > 1_920_000 {
                Text("This panel exceeds the maximum pixel count.").foregroundStyle(.red)
            }
        }
        .navigationTitle("Panel")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func number(_ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { fields[key]?.intValue ?? fallback }, set: { value in
            var next = fields
            next[key] = .number(Double(value))
            profile = .object(next)
        })
    }
}

private let widgetNames = [
    "energy": "Electricity", "weather": "Weather", "news": "News", "calendar": "Calendar",
    "status": "Status", "monta": "Monta", "zaptec": "Zaptec", "notion": "Notion",
    "custom-text": "Custom text", "custom-image": "Custom image", "custom-webhook": "Sensors"
]

private struct LayoutSettingsView: View {
    let apply: (JSONValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var layout: Preferences

    init(value: JSONValue?, apply: @escaping (JSONValue) -> Void) {
        self.apply = apply
        let defaults: [(String, Int, Int)] = [("energy", 0, 2), ("weather", 2, 2), ("news", 4, 1), ("status", 5, 1)]
        _layout = State(initialValue: value?.objectValue ?? [
            "version": .number(1), "cols": .number(10), "rows": .number(6),
            "widgets": .array(defaults.map { id, y, height in
                .object(["i": .string(id), "x": .number(0), "y": .number(Double(y)), "w": .number(10), "h": .number(Double(height))])
            })
        ])
    }

    private var widgets: [JSONValue] { layout["widgets"]?.arrayValue ?? [] }
    private var available: [String] {
        widgetNames.keys.filter { key in !widgets.contains { $0.objectValue?["i"]?.stringValue == key } }.sorted()
    }

    var body: some View {
        Form {
            Section {
                LayoutGrid(widgets: widgets).frame(height: 160)
                    .accessibilityLabel("Widget arrangement on a 10 column by 6 row grid")
            } footer: {
                Text("Move and resize widgets using grid positions. Widgets must fit within the screen without overlapping. Save in Settings to send your changes.")
            }
            ForEach(widgets.indices, id: \.self) { index in
                Section {
                    DisclosureGroup(widgetNames[widgetID(index)] ?? widgetID(index)) {
                        Stepper("Column: \(field(index, "x") + 1)", value: position(index, "x"), in: 0...9)
                        Stepper("Row: \(field(index, "y") + 1)", value: position(index, "y"), in: 0...5)
                        Stepper("Width: \(field(index, "w")) columns", value: position(index, "w"), in: 1...10)
                        Stepper("Height: \(field(index, "h")) rows", value: position(index, "h"), in: 1...6)
                        Button("Remove widget", role: .destructive) {
                            var next = widgets
                            guard next.indices.contains(index) else { return }
                            next.remove(at: index)
                            layout["widgets"] = .array(next)
                        }
                    }
                }
            }
            Section {
                Menu("Add widget", systemImage: "plus") {
                    ForEach(available, id: \.self) { id in
                        Button(widgetNames[id] ?? id) { add(id) }
                    }
                }.disabled(available.isEmpty || freeCell == nil)
                if freeCell == nil { Text("Make room by resizing or removing a widget.").font(.footnote).foregroundStyle(.secondary) }
            }
            if let validationError {
                Section { Text(validationError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Arrange widgets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { apply(.object(layout)); dismiss() }.disabled(validationError != nil)
            }
        }
    }

    private func widgetID(_ index: Int) -> String {
        guard widgets.indices.contains(index) else { return "Widget" }
        return widgets[index].objectValue?["i"]?.stringValue ?? "Widget"
    }
    private func field(_ index: Int, _ key: String) -> Int {
        guard widgets.indices.contains(index) else { return 0 }
        return widgets[index].objectValue?[key]?.intValue ?? 0
    }
    private func position(_ index: Int, _ key: String) -> Binding<Int> {
        Binding(get: { field(index, key) }, set: { value in
            var next = widgets
            guard next.indices.contains(index), var widget = next[index].objectValue else { return }
            widget[key] = .number(Double(value))
            next[index] = .object(widget)
            layout["widgets"] = .array(next)
        })
    }
    private var freeCell: (Int, Int)? {
        guard validationError == nil else { return nil }
        for y in 0..<6 {
            for x in 0..<10 {
                if !widgets.indices.contains(where: { index in
                    x >= field(index, "x") && x < field(index, "x") + field(index, "w") &&
                    y >= field(index, "y") && y < field(index, "y") + field(index, "h")
                }) { return (x, y) }
            }
        }
        return nil
    }
    private func add(_ id: String) {
        guard let (x, y) = freeCell else { return }
        layout["widgets"] = .array(widgets + [.object([
            "i": .string(id), "x": .number(Double(x)), "y": .number(Double(y)), "w": .number(1), "h": .number(1)
        ])])
    }
    private var validationError: String? {
        layoutValidationError(widgets)
    }
}

// Pure validation mirrors the server grid bounds so invalid edits never enable Done.
func layoutValidationError(_ widgets: [JSONValue]) -> String? {
    var rectangles: [(x: Int, y: Int, w: Int, h: Int)] = []
    var ids = Set<String>()
    for item in widgets {
        guard let widget = item.objectValue, let id = widget["i"]?.stringValue,
              ids.insert(id).inserted,
              let x = widget["x"]?.intValue, let y = widget["y"]?.intValue,
              let w = widget["w"]?.intValue, let h = widget["h"]?.intValue,
              (0..<10).contains(x), (0..<6).contains(y), (1...10).contains(w), (1...6).contains(h),
              x + w <= 10, y + h <= 6 else {
            return "Each widget must be unique and fit within the 10 × 6 grid."
        }
        if rectangles.contains(where: { x < $0.x + $0.w && x + w > $0.x && y < $0.y + $0.h && y + h > $0.y }) {
            return "Widgets overlap. Move or resize them before finishing."
        }
        rectangles.append((x, y, w, h))
    }
    return nil
}

private struct LayoutGrid: View {
    let widgets: [JSONValue]
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                ForEach(widgets.indices, id: \.self) { index in
                    let widget = widgets[index].objectValue ?? [:]
                    let id = widget["i"]?.stringValue ?? ""
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.teal.opacity(0.12))
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(.teal, lineWidth: 1) }
                        .overlay { Text(widgetNames[id] ?? id).font(.caption2).lineLimit(1).padding(3) }
                        .frame(width: max(0, geometry.size.width * CGFloat(widget["w"]?.intValue ?? 1) / 10 - 4), height: max(0, geometry.size.height * CGFloat(widget["h"]?.intValue ?? 1) / 6 - 4))
                        .offset(x: geometry.size.width * CGFloat(widget["x"]?.intValue ?? 0) / 10 + 2, y: geometry.size.height * CGFloat(widget["y"]?.intValue ?? 0) / 6 + 2)
                }
            }.clipped()
        }.accessibilityHidden(true)
    }
}

private struct CredentialsView: View {
    let api: APIClient
    @State private var keys: [MaskedApiKey] = []
    @State private var calendarConfigured = false
    @State private var provider = "openweathermap"
    @State private var newKey = ""
    @State private var calendarURL = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var removing: String?
    @State private var confirmRemove = false

    private let providers = ["openweathermap": "OpenWeather", "newsapi": "NewsAPI", "openai": "OpenAI"]

    var body: some View {
        Form {
            if !loaded {
                if busy { ProgressView("Loading credential status…") }
                else { Button("Try again") { Task { await load() } } }
            }
            Section {
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(providers[key.provider] ?? key.provider.capitalized).font(.headline)
                        Text(key.api_key).font(.caption.monospaced()).foregroundStyle(.secondary).privacySensitive()
                        Button("Remove", role: .destructive) {
                            removing = key.provider
                            confirmRemove = true
                        }
                    }
                }
                if loaded && keys.isEmpty { Text("No API keys configured").foregroundStyle(.secondary) }
            } header: { Text("Stored keys") }
            Section {
                Picker("Service", selection: $provider) {
                    Text("OpenWeather").tag("openweathermap")
                    Text("NewsAPI").tag("newsapi")
                    Text("OpenAI").tag("openai")
                }
                SecureField("New API key", text: $newKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Button("Save API key") { Task { await saveKey() } }
                    .disabled(!loaded || newKey.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
            } header: { Text("Add or replace a key") } footer: {
                Text("The server stores service credentials. The app only retrieves the masked version.")
            }
            Section {
                LabeledContent("Feed", value: calendarConfigured ? "Configured" : "Not configured")
                SecureField("Private HTTPS calendar feed URL", text: $calendarURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).privacySensitive()
                Button("Save calendar feed") { Task { await saveCalendar() } }
                    .disabled(!loaded || calendarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if calendarConfigured {
                    Button("Remove calendar feed", role: .destructive) {
                        removing = "calendar"
                        confirmRemove = true
                    }
                }
            } header: { Text("Calendar") } footer: {
                Text("Use an iCalendar subscription URL accessible over HTTPS. Private feed URLs may include an access token; the server never returns the saved URL.")
            }
            if let notice { Section { Text(notice).foregroundStyle(.teal) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(busy)
        .navigationTitle("Service credentials")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { newKey = ""; calendarURL = "" }
        .confirmationDialog("Remove this credential?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("The associated content will be unavailable on your displays until a credential is added again.")
        }
    }

    @MainActor private func load() async {
        busy = true
        defer { busy = false }
        do {
            async let loadedKeys = api.apiKeys()
            async let loadedCalendar = api.calendarCredentialConfigured()
            (keys, calendarConfigured) = try await (loadedKeys, loadedCalendar)
            loaded = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func saveKey() async {
        busy = true
        defer { busy = false }
        do {
            let key = try await api.saveAPIKey(provider: provider, key: newKey.trimmingCharacters(in: .whitespacesAndNewlines))
            keys.removeAll { $0.provider == key.provider }
            keys.append(key)
            newKey = ""
            notice = "API key saved."
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func saveCalendar() async {
        busy = true
        defer { busy = false }
        do {
            calendarConfigured = try await api.saveCalendarCredential(url: calendarURL.trimmingCharacters(in: .whitespacesAndNewlines))
            calendarURL = ""
            notice = "Calendar feed saved."
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func remove() async {
        guard let removing else { return }
        busy = true
        defer { busy = false }
        do {
            if removing == "calendar" {
                calendarConfigured = try await api.deleteCalendarCredential()
            } else {
                try await api.deleteAPIKey(provider: removing)
                keys.removeAll { $0.provider == removing }
            }
            notice = "Credential removed."
            error = nil
            self.removing = nil
        } catch { self.error = error.localizedDescription }
    }
}
