import Foundation
import CoreBluetooth
import CryptoKit
import CommonCrypto
import Combine

// MARK: - Reading

struct CMFWatchReading: Sendable {
    let level: Int
    let charging: Bool
    let name: String
    let mac: String?
}

enum CMFWatchError: Error, Sendable, CustomStringConvertible {
    case busy
    case bluetooth(String)
    case timeout(String)
    case protocolError(String)
    case crypto(String)

    var description: String {
        switch self {
        case .busy:
            return "another read is already running"
        case .bluetooth(let message):
            return "Bluetooth: \(message)"
        case .timeout(let message):
            return "timeout while \(message)"
        case .protocolError(let message):
            return "protocol error: \(message)"
        case .crypto(let message):
            return "crypto error: \(message)"
        }
    }
}

// MARK: - Reader

/// Reads the real CMF Watch Pro 2 battery through the same proprietary
/// authenticated channel that Nothing X uses. The standard Battery Service
/// (`0x180F` / `0x2A19`) on this watch reports a constant placeholder, so it
/// cannot be used. Only read-only commands are sent: the shell secret request,
/// the pairing handshake, `TIME` and `BATTERY`.
final class CMFWatchBatteryReader: NSObject, @unchecked Sendable {
    static let shared = CMFWatchBatteryReader()

    private static var cmdServiceUUID: CBUUID { CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB") }
    private static var cmdWriteUUID: CBUUID { CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB") }
    private static var cmdNotifyUUID: CBUUID { CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB") }

    private static var shellServiceUUID: CBUUID { CBUUID(string: "77D4E67C-2FE2-2334-0D35-9CCD078F529C") }
    private static var shellWriteUUID: CBUUID { CBUUID(string: "77D4FF01-2FE2-2334-0D35-9CCD078F529C") }
    private static var shellNotifyUUID: CBUUID { CBUUID(string: "77D4FF02-2FE2-2334-0D35-9CCD078F529C") }

    private static var advertisedServiceUUID: CBUUID { CBUUID(string: "EFE7") }
    private static let aesIV = Data([
        0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
        0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x5A
    ])

    private let centralQueue = DispatchQueue(label: "BatteryWidget.CMF.central")
    private let flowQueue = DispatchQueue(label: "BatteryWidget.CMF.flow", qos: .utility)
    private var central: CBCentralManager!

    private var peripheral: CBPeripheral?
    private var cmdService: CBService?
    private var shellService: CBService?
    private var cmdWrite: CBCharacteristic?
    private var cmdNotify: CBCharacteristic?
    private var shellWrite: CBCharacteristic?
    private var shellNotify: CBCharacteristic?

    private var managerState: CBManagerState = .unknown
    private let managerCondition = NSCondition()

    private var connectionReady = false
    private var connectionError: Error?
    private let connectionCondition = NSCondition()

    private var servicesReady = false
    private var servicesError: Error?
    private let servicesCondition = NSCondition()

    private var characteristicsError: Error?
    private let characteristicsCondition = NSCondition()

    private var notificationsEnabled = 0
    private var notificationError: Error?
    private let notificationCondition = NSCondition()

    private var pendingFrames: [(UInt16, UInt16, Data)] = []
    private let frameCondition = NSCondition()
    private var frameBuffer: [UInt8] = []

    private var shellText = ""
    private let shellCondition = NSCondition()

    private var currentKey: Data?

    private let readLock = NSLock()
    private var isReading = false

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: centralQueue,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        managerState = central.state
    }

    /// Runs one complete authenticated read. The completion is called on an
    /// internal queue; the caller is responsible for hopping to the main actor.
    func read(completion: @escaping @Sendable (Result<CMFWatchReading, CMFWatchError>) -> Void) {
        readLock.lock()
        guard !isReading else {
            readLock.unlock()
            completion(.failure(.busy))
            return
        }
        isReading = true
        readLock.unlock()

        flowQueue.async { [self] in
            let result: Result<CMFWatchReading, CMFWatchError>
            do {
                result = .success(try performRead())
            } catch let error as CMFWatchError {
                result = .failure(error)
            } catch {
                result = .failure(.protocolError(String(describing: error)))
            }
            finishRead()
            completion(result)
        }
    }

    // MARK: Read flow

    private func performRead() throws -> CMFWatchReading {
        resetForRead()
        try waitForPowerOn()
        try acquirePeripheral()
        try discoverServices()
        try discoverCharacteristics()
        try enableNotifications()

        let secret = try readSecret()
        let mac = try authenticate(secret: secret)
        try sendTime()
        let battery = try readBattery()

        return CMFWatchReading(
            level: battery.level,
            charging: battery.charging,
            name: peripheral?.name ?? "CMF Watch Pro 2",
            mac: mac
        )
    }

    private func resetForRead() {
        managerCondition.lock()
        managerState = central.state
        managerCondition.broadcast()
        managerCondition.unlock()

        connectionCondition.lock()
        connectionReady = false
        connectionError = nil
        connectionCondition.broadcast()
        connectionCondition.unlock()

        servicesCondition.lock()
        servicesReady = false
        servicesError = nil
        servicesCondition.broadcast()
        servicesCondition.unlock()

        characteristicsCondition.lock()
        characteristicsError = nil
        characteristicsCondition.broadcast()
        characteristicsCondition.unlock()

        notificationCondition.lock()
        notificationsEnabled = 0
        notificationError = nil
        notificationCondition.broadcast()
        notificationCondition.unlock()

        frameCondition.lock()
        pendingFrames.removeAll()
        frameCondition.broadcast()
        frameCondition.unlock()

        shellCondition.lock()
        shellText = ""
        shellCondition.broadcast()
        shellCondition.unlock()

        peripheral = nil
        cmdService = nil
        shellService = nil
        cmdWrite = nil
        cmdNotify = nil
        shellWrite = nil
        shellNotify = nil
        frameBuffer.removeAll()
        currentKey = nil
    }

    private func finishRead() {
        central.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        cmdService = nil
        shellService = nil
        cmdWrite = nil
        cmdNotify = nil
        shellWrite = nil
        shellNotify = nil
        currentKey = nil
        frameBuffer.removeAll()

        readLock.lock()
        isReading = false
        readLock.unlock()
    }

    // MARK: Waiting

    private func waitForPowerOn() throws {
        let deadline = Date().addingTimeInterval(12)
        managerCondition.lock()
        defer { managerCondition.unlock() }

        while managerState != .poweredOn {
            switch managerState {
            case .unauthorized:
                throw CMFWatchError.bluetooth("access denied; allow Bluetooth for BatteryWidget in Settings")
            case .unsupported:
                throw CMFWatchError.bluetooth("Bluetooth LE is not supported")
            case .poweredOff:
                throw CMFWatchError.bluetooth("Bluetooth is off")
            default:
                break
            }
            if !managerCondition.wait(until: deadline) {
                throw CMFWatchError.timeout("waiting for Bluetooth (state \(managerState.rawValue))")
            }
        }
    }

    private func acquirePeripheral() throws {
        let services = [
            Self.cmdServiceUUID,
            Self.shellServiceUUID,
            Self.advertisedServiceUUID,
            CBUUID(string: "180F")
        ]
        let candidates = central.retrieveConnectedPeripherals(withServices: services)
        if let watch = candidates.first(where: isWatch) {
            print("BatteryWidget CMF: using known peripheral \(watch.name ?? "?")")
            peripheral = watch
            watch.delegate = self
            if watch.state != .connected {
                try connect(watch)
            }
            return
        }

        try scanForWatch()
    }

    private func isWatch(_ peripheral: CBPeripheral) -> Bool {
        let name = peripheral.name ?? ""
        if name.localizedCaseInsensitiveContains("CMF Watch") {
            return true
        }
        // Never grab earbuds that happen to share the Nothing manufacturer ID.
        return !name.localizedCaseInsensitiveContains("Buds")
            && name.localizedCaseInsensitiveContains("Watch")
    }

    private func scanForWatch() throws {
        let deadline = Date().addingTimeInterval(20)
        connectionCondition.lock()
        defer { connectionCondition.unlock() }

        connectionReady = false
        connectionError = nil
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        print("BatteryWidget CMF: scanning")

        while !connectionReady {
            if let error = connectionError { throw error }
            if !connectionCondition.wait(until: deadline) {
                central.stopScan()
                throw CMFWatchError.timeout("scanning for CMF Watch")
            }
        }
    }

    private func connect(_ peripheral: CBPeripheral) throws {
        let deadline = Date().addingTimeInterval(15)
        connectionCondition.lock()
        defer { connectionCondition.unlock() }

        connectionReady = false
        connectionError = nil
        central.connect(peripheral, options: nil)
        print("BatteryWidget CMF: connecting")

        while !connectionReady {
            if let error = connectionError { throw error }
            if !connectionCondition.wait(until: deadline) {
                central.cancelPeripheralConnection(peripheral)
                throw CMFWatchError.timeout("connecting to CMF Watch")
            }
        }
    }

    private func discoverServices() throws {
        guard let peripheral else { throw CMFWatchError.bluetooth("peripheral missing") }
        let deadline = Date().addingTimeInterval(12)
        servicesCondition.lock()
        defer { servicesCondition.unlock() }

        servicesReady = false
        servicesError = nil
        peripheral.discoverServices([Self.cmdServiceUUID, Self.shellServiceUUID])

        while !servicesReady {
            if let error = servicesError { throw error }
            if !servicesCondition.wait(until: deadline) {
                throw CMFWatchError.timeout("discovering services")
            }
        }
    }

    private func discoverCharacteristics() throws {
        guard let peripheral, let cmdService, let shellService else {
            throw CMFWatchError.bluetooth("services missing")
        }
        let deadline = Date().addingTimeInterval(12)
        characteristicsCondition.lock()
        defer { characteristicsCondition.unlock() }

        characteristicsError = nil
        peripheral.discoverCharacteristics([Self.cmdWriteUUID, Self.cmdNotifyUUID], for: cmdService)
        peripheral.discoverCharacteristics([Self.shellWriteUUID, Self.shellNotifyUUID], for: shellService)

        while true {
            if let error = characteristicsError { throw error }
            if cmdWrite != nil, cmdNotify != nil, shellWrite != nil, shellNotify != nil {
                return
            }
            if !characteristicsCondition.wait(until: deadline) {
                throw CMFWatchError.timeout("discovering characteristics")
            }
        }
    }

    private func enableNotifications() throws {
        guard let peripheral, let cmdNotify, let shellNotify else {
            throw CMFWatchError.bluetooth("notify characteristics missing")
        }
        let deadline = Date().addingTimeInterval(12)
        notificationCondition.lock()
        defer { notificationCondition.unlock() }

        notificationsEnabled = 0
        notificationError = nil
        peripheral.setNotifyValue(true, for: cmdNotify)
        peripheral.setNotifyValue(true, for: shellNotify)

        while notificationsEnabled < 2 {
            if let error = notificationError { throw error }
            if !notificationCondition.wait(until: deadline) {
                throw CMFWatchError.timeout("enabling notifications")
            }
        }
    }

    // MARK: Shell

    private func writeShell(_ command: String) throws {
        guard let peripheral, let shellWrite else {
            throw CMFWatchError.bluetooth("shell characteristic missing")
        }
        shellCondition.lock()
        shellText = ""
        shellCondition.unlock()
        peripheral.writeValue(Data(command.utf8), for: shellWrite, type: .withResponse)
    }

    private func waitForShellResponse(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        shellCondition.lock()
        defer { shellCondition.unlock() }

        while true {
            if let range = shellText.range(of: ",OK") {
                let response = String(shellText[..<range.lowerBound])
                shellText = String(shellText[range.upperBound...])
                return response
            }
            if !shellCondition.wait(until: deadline) {
                throw CMFWatchError.timeout("waiting for shell response")
            }
        }
    }

    private func handleShellData(_ data: Data) {
        shellCondition.lock()
        if let text = String(data: data, encoding: .utf8) {
            shellText += text
        }
        let snapshot = shellText
        shellCondition.broadcast()
        shellCondition.unlock()

        // The secret must never reach a log. Only confirm that the reply came.
        if snapshot.contains("GETSECRET:") {
            print("BatteryWidget CMF: secret response received")
        } else {
            let sanitized = snapshot
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            print("BatteryWidget CMF shell: \(sanitized)")
        }
    }

    private func readSecret() throws -> Data {
        try writeShell("AT GETSECRET")
        let response = try waitForShellResponse(timeout: 8)
        guard let marker = response.range(of: "GETSECRET:") else {
            throw CMFWatchError.protocolError("unexpected GETSECRET reply")
        }
        let hex = String(response[marker.upperBound...].prefix(32))
        guard hex.count == 32, let secret = Data(hexString: hex), secret.count == 16 else {
            throw CMFWatchError.protocolError("bad secret length")
        }
        return secret
    }

    // MARK: Authentication

    private func authenticate(secret: Data) throws -> String? {
        let random1 = Self.randomData(16)
        let signed1 = Self.sha256(random1 + secret)
        try sendCommand(0xFFFF, 0x8047, payload: random1 + signed1, encrypted: false)

        let pairReply = try waitForCommand(0xFFFF, 0x0048, timeout: 10)
        guard pairReply.count >= 48 else {
            throw CMFWatchError.protocolError("AUTH_PAIR_REPLY is \(pairReply.count) bytes")
        }
        let random2 = Data(pairReply.prefix(16))
        let signed2 = Data(pairReply.dropFirst(16).prefix(32))
        guard signed2 == Self.sha256(random2 + secret) else {
            throw CMFWatchError.protocolError("AUTH_PAIR_REPLY signature mismatch")
        }

        let authKey = Data(Self.sha256(random1 + random2 + secret).prefix(16))
        currentKey = authKey

        try sendCommand(
            0xFFFF, 0x8049,
            payload: Data([0xA5]) + Data("BatteryWidget".utf8),
            encrypted: true
        )
        let macReply = try waitForCommand(0xFFFF, 0x0049, timeout: 10)
        let mac = Self.parseMAC(macReply)
        print("BatteryWidget CMF: authenticated, watch MAC received")

        try sendCommand(0xFFFF, 0x804B, payload: Data([0xA5]), encrypted: true)
        let nonce = try waitForCommand(0xFFFF, 0x004C, timeout: 10)
        guard nonce.count >= 16 else {
            throw CMFWatchError.protocolError("nonce is \(nonce.count) bytes")
        }

        let sessionKey = Data(Self.sha256(Data(nonce.prefix(16)) + authKey).prefix(16))
        currentKey = sessionKey

        try sendCommand(0xFFFF, 0x804D, payload: Data([0xA5]), encrypted: true)
        _ = try waitForCommand(0xFFFF, 0x0004, timeout: 10)
        print("BatteryWidget CMF: session confirmed")
        return mac
    }

    private func sendTime() throws {
        let now = Date()
        let epoch = Int32(now.timeIntervalSince1970)
        let offset = Int32(TimeZone.current.secondsFromGMT(for: now) * 1000)
        let payload = Self.be32(UInt32(bitPattern: epoch)) + Self.be32(UInt32(bitPattern: offset))
        try sendCommand(0xFFFF, 0x8004, payload: payload, encrypted: true)
    }

    private func readBattery() throws -> (level: Int, charging: Bool) {
        // The watch usually pushes BATTERY right after TIME. If it does not,
        // ask explicitly. An empty payload is a header-only command.
        if let pushed = try? waitForCommand(0x005C, 0x0001, timeout: 3) {
            return try Self.parseBattery(pushed)
        }
        try sendCommand(0x005C, 0x0001, payload: Data(), encrypted: true)
        let reply = try waitForCommand(0x005C, 0x0001, timeout: 8)
        return try Self.parseBattery(reply)
    }

    private static func parseBattery(_ payload: Data) throws -> (level: Int, charging: Bool) {
        guard payload.count >= 2 else {
            throw CMFWatchError.protocolError("BATTERY reply is \(payload.count) bytes")
        }
        let level = Int(payload[payload.startIndex])
        let charging = payload[payload.startIndex + 1] == 0x01
        guard (0...100).contains(level) else {
            throw CMFWatchError.protocolError("BATTERY level \(level) is out of range")
        }
        return (level, charging)
    }

    private static func parseMAC(_ payload: Data) -> String? {
        let bytes = Array(payload)
        let macBytes: [UInt8]
        if bytes.count >= 7, bytes[0] == 0x5A {
            macBytes = Array(bytes[1...6])
        } else if bytes.count >= 6 {
            macBytes = Array(bytes[0...5])
        } else {
            return nil
        }
        return macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Framing and crypto

    private func makeFrame(cmd1: UInt16, cmd2: UInt16, payload: Data, encrypted: Bool) throws -> Data {
        let chunk: Data
        if payload.isEmpty {
            chunk = Data()
        } else if encrypted {
            guard let key = currentKey else {
                throw CMFWatchError.crypto("no session key")
            }
            let plain = payload + Self.crc32LE(payload)
            guard let cipher = Self.aesCBC(CCOperation(kCCEncrypt), data: plain, key: key) else {
                throw CMFWatchError.crypto("AES encryption failed")
            }
            chunk = cipher
        } else {
            chunk = payload + Self.crc32LE(payload)
        }

        var frame = Data()
        frame.append(0xF5)
        frame.append(Self.be16(UInt16(chunk.count)))
        frame.append(Self.be16(cmd1))
        frame.append(Self.be16(1))
        frame.append(Self.be16(1))
        frame.append(Self.be16(cmd2))
        frame.append(chunk)
        return frame
    }

    private func sendCommand(_ cmd1: UInt16, _ cmd2: UInt16, payload: Data, encrypted: Bool) throws {
        guard let peripheral, let cmdWrite else {
            throw CMFWatchError.bluetooth("command characteristic missing")
        }
        let frame = try makeFrame(cmd1: cmd1, cmd2: cmd2, payload: payload, encrypted: encrypted)
        peripheral.writeValue(frame, for: cmdWrite, type: .withResponse)
    }

    private func waitForCommand(_ cmd1: UInt16, _ cmd2: UInt16, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        frameCondition.lock()
        defer { frameCondition.unlock() }

        while true {
            if let index = pendingFrames.firstIndex(where: { $0.0 == cmd1 && $0.1 == cmd2 }) {
                return pendingFrames.remove(at: index).2
            }
            if !frameCondition.wait(until: deadline) {
                throw CMFWatchError.timeout(String(format: "waiting for %04X %04X", cmd1, cmd2))
            }
        }
    }

    private func appendFrame(cmd1: UInt16, cmd2: UInt16, payload: Data) {
        frameCondition.lock()
        pendingFrames.append((cmd1, cmd2, payload))
        frameCondition.broadcast()
        frameCondition.unlock()
    }

    private func be16At(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    private func handleFrameData(_ data: Data) {
        frameBuffer.append(contentsOf: data)

        while true {
            guard frameBuffer.count >= 11 else { return }
            guard frameBuffer[0] == 0xF5 else {
                frameBuffer.removeFirst()
                continue
            }

            let chunkLength = Int(be16At(frameBuffer, 1))
            let cmd1 = be16At(frameBuffer, 3)
            let chunkCount = be16At(frameBuffer, 5)
            let cmd2 = be16At(frameBuffer, 9)
            let available = frameBuffer.count - 11
            let isPlaintext = (cmd1 == 0xFFFF && cmd2 == 0x0048)

            if chunkCount > 1 {
                print("BatteryWidget CMF: chunked frame \(cmd2) \(chunkCount) chunks")
            }

            if isPlaintext {
                if available >= chunkLength, chunkLength > 0 {
                    var chunk = Data(frameBuffer[11..<11 + chunkLength])
                    frameBuffer.removeFirst(11 + chunkLength)
                    if chunk.count >= 4, Self.crc32(chunk.dropLast(4)) == Self.readLE32(chunk.suffix(4)) {
                        chunk = Data(chunk.dropLast(4))
                    }
                    appendFrame(cmd1: cmd1, cmd2: cmd2, payload: chunk)
                } else if available >= 48 {
                    var chunk = Data(frameBuffer[11..<11 + 48])
                    frameBuffer.removeFirst(11 + 48)
                    if chunk.count == 52, Self.crc32(chunk.dropLast(4)) == Self.readLE32(chunk.suffix(4)) {
                        chunk = Data(chunk.dropLast(4))
                    }
                    appendFrame(cmd1: cmd1, cmd2: cmd2, payload: chunk)
                } else {
                    return
                }
            } else if chunkLength == 0 {
                frameBuffer.removeFirst(11)
                appendFrame(cmd1: cmd1, cmd2: cmd2, payload: Data())
            } else {
                guard available >= chunkLength else { return }
                let cipher = Data(frameBuffer[11..<11 + chunkLength])
                frameBuffer.removeFirst(11 + chunkLength)

                guard let key = currentKey else { return }
                guard let plain = Self.aesCBC(CCOperation(kCCDecrypt), data: cipher, key: key) else {
                    print("BatteryWidget CMF: AES decrypt failed")
                    continue
                }
                guard plain.count >= 4 else { continue }

                let payload = Data(plain.dropLast(4))
                let expected = Self.readLE32(plain.suffix(4))
                guard Self.crc32(payload) == expected else {
                    print("BatteryWidget CMF: CRC mismatch")
                    continue
                }
                appendFrame(cmd1: cmd1, cmd2: cmd2, payload: payload)
            }
        }
    }

    private static func be16(_ value: UInt16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }

    private static func be32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    private static func readLE32(_ data: Data) -> UInt32 {
        let bytes = Array(data)
        guard bytes.count >= 4 else { return 0 }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func crc32LE(_ data: Data) -> Data {
        var value = crc32(data).littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private static func aesCBC(_ operation: CCOperation, data: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    aesIV.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outputBytes.baseAddress, capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(outputLength))
    }
}

// MARK: - CoreBluetooth

extension CMFWatchBatteryReader: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        managerCondition.lock()
        managerState = central.state
        managerCondition.broadcast()
        managerCondition.unlock()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertisesEFE7 = services.contains { $0.uuidString.uppercased().contains("EFE7") }

        let matchesName = name.localizedCaseInsensitiveContains("CMF Watch")
        guard matchesName || advertisesEFE7 else { return }
        guard !name.localizedCaseInsensitiveContains("Buds") else { return }

        print("BatteryWidget CMF: found \(name) rssi \(RSSI.intValue)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self

        connectionCondition.lock()
        connectionReady = false
        connectionError = nil
        connectionCondition.broadcast()
        connectionCondition.unlock()

        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionCondition.lock()
        connectionReady = true
        connectionCondition.broadcast()
        connectionCondition.unlock()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionCondition.lock()
        connectionError = CMFWatchError.bluetooth(
            "connect failed: \(error?.localizedDescription ?? "unknown")"
        )
        connectionCondition.broadcast()
        connectionCondition.unlock()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        print("BatteryWidget CMF: disconnected \(error?.localizedDescription ?? "")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        servicesCondition.lock()
        defer {
            servicesCondition.broadcast()
            servicesCondition.unlock()
        }

        if let error {
            servicesError = CMFWatchError.bluetooth("discoverServices: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            servicesError = CMFWatchError.protocolError("no services")
            return
        }

        for service in services {
            if service.uuid == Self.cmdServiceUUID { cmdService = service }
            if service.uuid == Self.shellServiceUUID { shellService = service }
        }
        guard cmdService != nil, shellService != nil else {
            servicesError = CMFWatchError.protocolError("CMF services not found")
            return
        }
        servicesReady = true
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        characteristicsCondition.lock()
        defer {
            characteristicsCondition.broadcast()
            characteristicsCondition.unlock()
        }

        if let error {
            characteristicsError = CMFWatchError.bluetooth(
                "discoverCharacteristics: \(error.localizedDescription)"
            )
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.cmdWriteUUID: cmdWrite = characteristic
            case Self.cmdNotifyUUID: cmdNotify = characteristic
            case Self.shellWriteUUID: shellWrite = characteristic
            case Self.shellNotifyUUID: shellNotify = characteristic
            default: break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        notificationCondition.lock()
        defer {
            notificationCondition.broadcast()
            notificationCondition.unlock()
        }

        if let error {
            notificationError = CMFWatchError.bluetooth(
                "notify \(characteristic.uuid.uuidString): \(error.localizedDescription)"
            )
            return
        }
        if characteristic.isNotifying {
            notificationsEnabled += 1
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            print("BatteryWidget CMF: write failed: \(error.localizedDescription)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            print("BatteryWidget CMF: value error: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }

        if characteristic.uuid == Self.cmdNotifyUUID {
            handleFrameData(value)
        } else if characteristic.uuid == Self.shellNotifyUUID {
            handleShellData(value)
        }
    }
}

// MARK: - Data helpers

private extension Data {
    init?(hexString: String) {
        let clean = hexString.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var result = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}

// MARK: - Monitor

/// Polls the watch every few minutes and keeps the last good reading. The
/// watch is not kept connected: a short session avoids competing with
/// Nothing X for the whole day, and the cached value stays visible until it
/// becomes stale.
@MainActor
final class CMFWatchBatteryMonitor: ObservableObject {
    static let shared = CMFWatchBatteryMonitor()

    @Published private(set) var watch: DeviceBatteryInfo?

    private var timer: Timer?
    private var retryTimer: Timer?
    private var isReading = false
    private var lastAttempt: Date?
    private var failures = 0

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        let refreshTimer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer.tolerance = 30
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    func refreshIfNeeded() {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 {
            return
        }
        refresh()
    }

    func refresh() {
        guard !isReading else { return }
        isReading = true
        lastAttempt = .now

        CMFWatchBatteryReader.shared.read { result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReading = false
                switch result {
                case .success(let reading):
                    self.failures = 0
                    self.watch = self.deviceInfo(from: reading)
                    print("BatteryWidget CMF: \(reading.level)% charging=\(reading.charging)")
                case .failure(let error):
                    self.failures += 1
                    print("BatteryWidget CMF: read failed: \(error)")
                    self.scheduleRetry()
                }
            }
        }
    }

    private func deviceInfo(from reading: CMFWatchReading) -> DeviceBatteryInfo {
        let id: String
        if let mac = reading.mac {
            let compact = mac
                .replacingOccurrences(of: ":", with: "")
                .lowercased()
            id = "cmf-watch-\(compact)"
        } else {
            id = "cmf-watch"
        }

        return DeviceBatteryInfo(
            id: id,
            deviceType: .appleWatch,
            deviceName: reading.name,
            batteryLevel: Double(reading.level) / 100.0,
            batteryState: reading.charging ? .charging : .discharging,
            isBatteryReadingAvailable: true
        )
    }

    private func scheduleRetry() {
        guard failures <= 3, retryTimer == nil else { return }
        let retry = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retryTimer = nil
                self?.refresh()
            }
        }
        RunLoop.main.add(retry, forMode: .common)
        retryTimer = retry
    }
}
