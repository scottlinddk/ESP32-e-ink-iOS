import Combine
import CoreBluetooth
import Foundation
import UIKit

struct DiscoveredDisplay: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// One foreground transfer at a time. ATT completion and the display's own ACK are both required.
@MainActor
final class BluetoothController: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredDisplay] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Scan for a nearby display."
    @Published private(set) var progress = 0.0

    private enum Operation: Equatable { case connect, services, characteristic, subscribe, read, write, configuration, reply }
    private let odUUID = CBUUID(string: OpenDisplayProtocol.serviceUUID)
    private let bundledUUID = CBUUID(string: OpenDisplayProtocol.bundledServiceUUID)
    private let bundledCharacteristicUUID = CBUUID(string: OpenDisplayProtocol.bundledCharacteristicUUID)
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var bundled = false
    private var scanRequested = false
    private var scanTimer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var pending: CheckedContinuation<Void, Error>?
    private var operation: Operation?
    private var operationID: UUID?
    private var transferID: UUID?
    private var failure: Error?
    private var readResult: Data?
    private var configuration: OpenDisplayProtocol.ConfigurationReply?
    private var panelResult: OpenDisplayProtocol.PanelCapabilities?
    private var replies: [UInt16] = []

    override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        scanTimer?.cancel()
        deadline?.cancel()
    }

    func startScan() {
        guard !isBusy else { return }
        stopScan()
        devices = []
        peripherals = [:]
        scanRequested = true
        status = "Starting Bluetooth…"
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            beginScan()
        } else if let central {
            centralManagerDidUpdateState(central)
        }
    }

    func stopScan() {
        scanRequested = false
        central?.stopScan()
        isScanning = false
        scanTimer?.cancel()
        scanTimer = nil
    }

    func cancel() {
        stopScan()
        guard isBusy else { return }
        fail(CancellationError())
        status = "Transfer cancelled. Scan again before retrying."
    }

    func push(pixels: Data, profile: DisplayProfile, device: DiscoveredDisplay) async throws {
        guard !isBusy else { throw DisplayBluetoothError("A display transfer is already in progress.") }
        try OpenDisplayProtocol.validateFrame(pixels: pixels, profile: profile)
        guard let central, central.state == .poweredOn else { throw DisplayBluetoothError("Turn on Bluetooth and scan for your display.") }
        guard let peripheral = peripherals[device.id], peripheral.state == .disconnected else {
            throw DisplayBluetoothError("The display is unavailable or still disconnecting. Scan again and retry.")
        }
        try Task.checkCancellation()
        stopScan()
        isBusy = true
        progress = 0
        failure = nil
        replies = []
        configuration = nil
        panelResult = nil
        readResult = nil
        active = peripheral
        transferID = UUID()
        peripheral.delegate = self
        let previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            deadline?.cancel()
            configuration = nil
            characteristic = nil
            peripheral.delegate = nil
            central.cancelPeripheralConnection(peripheral)
            active = nil
            transferID = nil
            replies = []
            isBusy = false
        }
        do {
            status = "Connecting to \(device.name)…"
            try await wait(for: .connect, seconds: 10) { central.connect(peripheral) }
            try await wait(for: .services, seconds: 10) { peripheral.discoverServices([self.bundledUUID, self.odUUID]) }
            let service: CBService
            if let found = peripheral.services?.first(where: { $0.uuid == bundledUUID }) {
                bundled = true
                service = found
            } else if let found = peripheral.services?.first(where: { $0.uuid == odUUID }) {
                bundled = false
                service = found
            } else { throw DisplayBluetoothError("This display does not expose a supported image service.") }
            let uuid = bundled ? bundledCharacteristicUUID : odUUID
            try await wait(for: .characteristic, seconds: 10) { peripheral.discoverCharacteristics([uuid], for: service) }
            guard let char = service.characteristics?.first(where: { $0.uuid == uuid }),
                  char.properties.contains(.write), char.properties.contains(.notify) || char.properties.contains(.indicate) else {
                throw DisplayBluetoothError("The display is missing its image-write or notification characteristic.")
            }
            characteristic = char
            status = "Checking display capabilities…"
            let panel: OpenDisplayProtocol.PanelCapabilities
            if bundled {
                guard char.properties.contains(.read) else { throw DisplayBluetoothError("The bundled display cannot report its capabilities.") }
                try await wait(for: .read, seconds: 5) { peripheral.readValue(for: char) }
                guard let readResult else { throw DisplayBluetoothError("The display returned no capabilities.") }
                panel = try OpenDisplayProtocol.parseBundledCapabilities(readResult)
                try await wait(for: .subscribe, seconds: 5) { peripheral.setNotifyValue(true, for: char) }
            } else {
                // Subscribe before issuing GET_CONFIG, so an immediate notification cannot be lost.
                let configDeadline = Date().addingTimeInterval(5)
                try await wait(for: .subscribe, seconds: 5) { peripheral.setNotifyValue(true, for: char) }
                configuration = OpenDisplayProtocol.ConfigurationReply()
                try await write(OpenDisplayProtocol.frame(0x40), seconds: max(0, configDeadline.timeIntervalSinceNow))
                if panelResult == nil {
                    try await wait(for: .configuration, seconds: max(0, configDeadline.timeIntervalSinceNow)) { }
                }
                guard let result = panelResult else { throw DisplayBluetoothError("The display returned no configuration.") }
                panel = result
                configuration = nil
            }
            try OpenDisplayProtocol.validatePanel(panel, profile: profile, bundled: bundled)
            let chunkSize = try OpenDisplayProtocol.chunkSize(maximumWriteLength: peripheral.maximumWriteValueLength(for: .withResponse), bundled: bundled)
            status = "Sending image…"
            _ = try await exchange(0x70, expected: [0x70], seconds: 10)
            var offset = 0
            var autoEnded = false
            while offset < pixels.count {
                let end = min(offset + chunkSize, pixels.count)
                let code = try await exchange(0x71, payload: pixels.subdata(in: offset..<end), expected: [0x71, 0x72], seconds: 90)
                offset = end
                progress = Double(offset) / Double(pixels.count)
                if code == 0x72 {
                    guard offset == pixels.count else { throw DisplayBluetoothError("The display ended the upload before accepting the complete image.") }
                    autoEnded = true
                    break
                }
            }
            try checkActive()
            status = "Waiting for display refresh…"
            if !autoEnded { _ = try await exchange(0x72, payload: Data([0]), expected: [0x72], seconds: 90) }
            _ = try await nextReply(expected: [0x73], seconds: 90)
            try checkActive()
            status = "Display confirmed its refresh."
        } catch {
            status = error is CancellationError ? "Transfer cancelled. Scan again before retrying." : error.localizedDescription
            throw error
        }
    }

    private func beginScan() {
        guard scanRequested, let central, central.state == .poweredOn, !isScanning else { return }
        isScanning = true
        status = "Looking for EInk and OpenDisplay devices…"
        // Some OpenDisplay firmware advertises only its name, so filter discovered records below.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self else { return }
            self.stopScan()
            self.status = self.devices.isEmpty ? "No display found. Wake the display and scan again." : "Choose a nearby display."
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard active != nil else { throw DisplayBluetoothError("The display connection is closed.") }
    }

    private func wait(for next: Operation, seconds: Double, start: () -> Void) async throws {
        try checkActive()
        let transfer = transferID
        guard seconds > 0 else { throw DisplayBluetoothError("The display operation timed out; refresh was not confirmed.") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard pending == nil else { continuation.resume(throwing: DisplayBluetoothError("Another Bluetooth operation is pending.")); return }
                let id = UUID()
                operationID = id
                operation = next
                pending = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                    guard let self, self.operationID == id else { return }
                    self.fail(DisplayBluetoothError("The display operation timed out; refresh was not confirmed."))
                }
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // A cancellation task from an old upload must not cancel a new one.
                guard let self, self.transferID == transfer else { return }
                self.fail(CancellationError())
            }
        }
        try checkActive()
    }

    private func complete(_ result: Result<Void, Error> = .success(())) {
        let continuation = pending
        pending = nil
        operation = nil
        operationID = nil
        deadline?.cancel()
        deadline = nil
        continuation?.resume(with: result)
    }

    private func fail(_ error: Error) {
        guard isBusy else { return }
        if failure == nil { failure = error }
        complete(.failure(failure ?? error))
        if let active { central?.cancelPeripheralConnection(active) }
    }

    private func write(_ bytes: Data, seconds: Double) async throws {
        guard let active, let characteristic else { throw DisplayBluetoothError("The display is disconnected.") }
        guard bytes.count <= active.maximumWriteValueLength(for: .withResponse) else {
            throw DisplayBluetoothError("The Bluetooth command exceeds the display's write limit.")
        }
        try await wait(for: .write, seconds: seconds) { active.writeValue(bytes, for: characteristic, type: .withResponse) }
    }

    private func exchange(_ command: UInt16, payload: Data = Data(), expected: [UInt16], seconds: Double) async throws -> UInt16 {
        try checkActive()
        guard replies.isEmpty else { throw DisplayBluetoothError("An unsolicited display acknowledgement arrived before the next command.") }
        let end = Date().addingTimeInterval(seconds)
        try await write(OpenDisplayProtocol.frame(command, payload: payload), seconds: seconds)
        return try await nextReply(expected: expected, seconds: max(0, end.timeIntervalSinceNow))
    }

    private func nextReply(expected: [UInt16], seconds: Double) async throws -> UInt16 {
        try checkActive()
        if replies.isEmpty { try await wait(for: .reply, seconds: seconds) { } }
        guard !replies.isEmpty else { throw DisplayBluetoothError("No display acknowledgement arrived.") }
        let code = replies.removeFirst()
        guard expected.contains(code) else { throw DisplayBluetoothError("Unexpected display acknowledgement 0x\(String(code, radix: 16)).") }
        return code
    }
}

// CBCentralManager was created on the main queue, which also delivers its peripheral callbacks.
extension BluetoothController: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { beginScan(); return }
        let message: String
        switch central.state {
        case .unauthorized: message = "Allow Bluetooth access in iPhone Settings to connect your display."
        case .poweredOff: message = "Turn on Bluetooth to connect your display."
        case .unsupported: message = "Bluetooth is unavailable on this device. Use a physical iPhone."
        default: message = "Bluetooth is starting. Try scanning again in a moment."
        }
        status = message
        if central.state != .unknown && central.state != .resetting { stopScan() }
        if isBusy { fail(DisplayBluetoothError(message)) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isScanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unnamed display"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.hasPrefix("EInk-") || name.hasPrefix("OD") || name.hasPrefix("OpenDisplay") || services.contains(bundledUUID) || services.contains(odUUID) else { return }
        peripherals[peripheral.identifier] = peripheral
        let record = DiscoveredDisplay(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == record.id }) { devices[index] = record } else { devices.append(record) }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active === peripheral, operation == .connect, failure == nil else { central.cancelPeripheralConnection(peripheral); return }
        complete()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active === peripheral else { return }
        fail(error ?? DisplayBluetoothError("Could not connect to the display."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active === peripheral else { return }
        fail(error ?? DisplayBluetoothError("The display disconnected before refresh was confirmed."))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active === peripheral, operation == .services else { return }
        if let error { fail(error) } else { complete() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active === peripheral, operation == .characteristic else { return }
        if let error { fail(error) } else { complete() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, self.characteristic === characteristic, operation == .subscribe else { return }
        if let error { fail(error) }
        else if !characteristic.isNotifying { fail(DisplayBluetoothError("The display did not enable notifications.")) }
        else { complete() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, self.characteristic === characteristic, operation == .write else { return }
        if let error { fail(error) } else { complete() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, self.characteristic === characteristic, failure == nil else { return }
        if let error { fail(error); return }
        guard let data = characteristic.value else { fail(DisplayBluetoothError("The display returned an empty response.")); return }
        if operation == .read {
            readResult = data
            complete()
            return
        }
        do {
            if configuration != nil {
                if let panel = try configuration?.append(data) {
                    panelResult = panel
                    if operation == .configuration { complete() }
                }
            } else {
                let code = try OpenDisplayProtocol.acknowledgement(data)
                guard replies.count < 4 else { throw DisplayBluetoothError("Too many unsolicited display acknowledgements.") }
                replies.append(code)
                if operation == .reply { complete() }
            }
        } catch { fail(error) }
    }
}
