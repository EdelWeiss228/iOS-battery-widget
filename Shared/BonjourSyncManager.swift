import Foundation
import Network
import Combine

// MARK: - Bonjour Sync Manager
// Работает поверх локальной сети (включая режим модема iPhone ↔ Mac).
// Каждое устройство одновременно является и сервером и клиентом.

public final class BonjourSyncManager: ObservableObject, @unchecked Sendable {

    // MARK: - Public

    public static let shared = BonjourSyncManager()
    @Published public var remoteDevices: [DeviceBatteryInfo] = []

    // MARK: - Private

    private let serviceType = "_batterysync._tcp"
    private let domain     = "local."
    private var listener:  NWListener?
    private var connections: [String: NWConnection] = [:]
    private var browser:   NWBrowser?
    private let queue = DispatchQueue(label: "com.batterysync.bonjour", qos: .utility)

    private var localInfo: DeviceBatteryInfo?

    private init() {}

    // MARK: - Start

    public func start(localInfo: DeviceBatteryInfo) {
        self.localInfo = localInfo
        startListener()
        startBrowser()
    }

    public func update(localInfo: DeviceBatteryInfo) {
        self.localInfo = localInfo
        broadcastToAll()
    }

    // MARK: - Listener (Server)

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            listener = try NWListener(using: params)
            listener?.service = NWListener.Service(type: serviceType, domain: domain)

            listener?.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.handleIncoming(conn)
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:   print("[BonjourSync] Listener ready")
                case .failed(let err): print("[BonjourSync] Listener failed: \(err)")
                default: break
                }
            }

            listener?.start(queue: queue)
        } catch {
            print("[BonjourSync] Listener init error: \(error)")
        }
    }

    private func handleIncoming(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveData(from: conn)
    }

    // MARK: - Browser (Client)

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: serviceType, domain: domain), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    if name == self.localInfo?.id { continue }
                    if self.connections[name] == nil {
                        self.connect(to: result.endpoint, name: name)
                    }
                }
            }
        }

        browser?.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint, name: String) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        connections[name] = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[BonjourSync] Connected to \(name)")
                self.sendLocalInfo(to: conn)
                self.receiveData(from: conn)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: name)
            default: break
            }
        }

        conn.start(queue: queue)
    }

    // MARK: - Send / Receive

    private func sendLocalInfo(to conn: NWConnection) {
        guard let info = localInfo,
              let data = try? JSONEncoder().encode(info) else { return }

        let lengthHeader = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        let packet = lengthHeader + data
        conn.send(content: packet, completion: .idempotent)
    }

    private func broadcastToAll() {
        connections.values.forEach { sendLocalInfo(to: $0) }
    }

    private func receiveData(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, err in
            guard let self, let data, data.count == 4, err == nil else { return }
            let length = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) }))

            conn.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, err in
                if let payload, err == nil,
                   let info = try? JSONDecoder().decode(DeviceBatteryInfo.self, from: payload) {
                    DispatchQueue.main.async {
                        if let idx = self.remoteDevices.firstIndex(where: { $0.id == info.id }) {
                            self.remoteDevices[idx] = info
                        } else {
                            self.remoteDevices.append(info)
                        }
                    }
                }
                self.receiveData(from: conn)
            }
        }
    }
}
