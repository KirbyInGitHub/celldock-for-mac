import CellDockNetworkIPC
import Foundation

// Endpoints that let the `celldock` CLI and AI agents read
// modules and SMS, send SMS and run AT commands through the local API.
// Every endpoint shares the local API's loopback listener and bearer token;
// each capability is additionally gated by a scope the user turns on in
// Settings, so enabling the call API alone grants nothing new.

struct LocalAgentModule: Encodable {
    let id: String
    let name: String
    let active_session: Bool
    let primary_data: Bool
    let state: String
    let usb_identity: String?
    let firmware: String?
    let operator_name: String?
    let access_technology: String?
    let signal_dbm: Int?
    let signal_bars: Int
    let sim_state: String
    let registration: String
    let voice_registration: String
    let usbnet_mode: Int?
    let ims_bearer_active: Bool?
    let volte_session_available: Bool?
    let card_kind: String
    let network: LocalAgentNetwork
    let last_error: String?

    init(_ summary: CellularModuleSummary, networkMode: CellularNetworkMode) {
        let modem = summary.modem
        id = summary.id.rawValue
        name = summary.localizedDisplayName
        active_session = summary.isActiveSession
        primary_data = summary.isPrimaryData
        state = String(describing: modem.state)
        usb_identity = modem.usbIdentity
        firmware = modem.firmwareVersion
        operator_name = modem.operatorName
        access_technology = modem.accessTechnology
        signal_dbm = modem.signalDBm
        signal_bars = modem.signalBars
        sim_state = String(describing: modem.simState)
        registration = String(describing: modem.registrationState)
        voice_registration = String(describing: modem.voiceRegistrationState)
        usbnet_mode = modem.usbNetMode
        ims_bearer_active = modem.imsBearerActive
        volte_session_available = modem.volteSessionAvailable
        card_kind = String(describing: summary.cardKind)
        network = LocalAgentNetwork(summary.network, mode: networkMode)
        last_error = modem.lastError
    }
}

struct LocalAgentNetwork: Encodable {
    let mode: String
    let interface: String?
    let service_name: String?
    let active: Bool
    let link_active: Bool
    let system_primary: Bool
    let ipv4: String?
    let ipv4_router: String?
    let ipv6: String?
    let dns: [String]
    let last_error: String?

    init(_ status: CellularNetworkStatus, mode: CellularNetworkMode) {
        self.mode = String(describing: mode)
        interface = status.bsdName
        service_name = status.serviceName
        active = status.isActive
        link_active = status.isLinkActive
        system_primary = status.isSystemPrimary
        ipv4 = status.ipv4Address
        ipv4_router = status.ipv4Router
        ipv6 = status.ipv6Address
        dns = status.dnsServers
        last_error = status.lastError
    }
}

struct LocalAgentMessage: Encodable {
    let id: String
    let module: String?
    let direction: String
    let peer: String
    let body: String
    let timestamp: String
    let read: Bool
    let delivery: String?
    let delivery_detail: String?
    let verification_code: String?

    init(_ message: SMSMessage) {
        id = message.id
        module = message.moduleID?.rawValue
        direction = message.isOutgoing ? "outgoing" : "incoming"
        peer = message.sender
        body = message.body
        timestamp = ISO8601DateFormatter().string(from: message.timestamp)
        read = message.isRead
        delivery = message.deliveryState.map { String(describing: $0) }
        delivery_detail = message.deliveryDetail
        verification_code = message.isOutgoing ? nil : SMSVerificationCodeExtractor.extract(from: message.body)
    }
}

struct LocalAgentATResult: Encodable {
    let module: String
    let command: String
    let ok: Bool
    let output: String
    let error: String?
    let elapsed_ms: Int
}

struct LocalAgentSMSSendResult: Encodable {
    let request_id: String
    let module: String
    let to: String
    let status: String          // sent | failed | uncertain
    let detail: String?
    let replayed: Bool
}

/// Remembers SMS sends by request_id so a retried request never sends twice.
/// In memory only: after CellDock restarts, verify with GET /api/sms first.
@MainActor
final class LocalAgentIdempotencyStore {
    private enum Entry {
        case pending(fingerprint: String)
        case done(fingerprint: String, result: LocalAgentSMSSendResult)
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    enum Lookup {
        case new
        case pending
        case done(LocalAgentSMSSendResult)
        case conflict
    }

    func begin(_ request: LocalAgentSMSRequest) -> Lookup {
        let fingerprint = "\(request.to)|\(request.moduleID ?? "")|\(request.body)"
        switch entries[request.requestID] {
        case .none:
            entries[request.requestID] = .pending(fingerprint: fingerprint)
            order.append(request.requestID)
            if order.count > 500 { entries[order.removeFirst()] = nil }
            return .new
        case .pending(let existing)?:
            return existing == fingerprint ? .pending : .conflict
        case .done(let existing, let result)?:
            guard existing == fingerprint else { return .conflict }
            return .done(LocalAgentSMSSendResult(request_id: result.request_id, module: result.module,
                                                 to: result.to, status: result.status,
                                                 detail: result.detail, replayed: true))
        }
    }

    func finish(_ request: LocalAgentSMSRequest, result: LocalAgentSMSSendResult) {
        let fingerprint = "\(request.to)|\(request.moduleID ?? "")|\(request.body)"
        entries[request.requestID] = .done(fingerprint: fingerprint, result: result)
    }
}

/// Hands the local API token to the `celldock` CLI the way DJOneHub does: a
/// 0600 file in the user's Application Support folder, present only while
/// the API is running. The CLI reads it, so neither the user nor an agent
/// ever copies the token.
enum LocalAgentCLIAccessFile {
    static var url: URL {
        AppDataDirectory.userApplicationSupport().appendingPathComponent("cli-access.json")
    }

    static func write(token: String, endpoint: String) {
        let fileManager = FileManager.default
        let destination = url
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        let body: [String: Any] = ["version": 1, "endpoint": endpoint, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".cli-access.\(UUID().uuidString).json")
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, destination.path) != 0 {
            try? fileManager.removeItem(at: temporary)
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct LocalAgentGNSSStatus: Encodable {
    let module: String
    let enabled: Bool
    let state: String
    let satellites_in_view: Int?
    let fix: LocalAgentGNSSFix?
}

struct LocalAgentGNSSFix: Encodable {
    let timestamp: String
    let latitude: Double
    let longitude: Double
    let altitude_m: Double?
    let hdop: Double?
    let speed_kmh: Double?
    let satellites: Int?
    let datum = "WGS-84"

    init(_ fix: GNSSFix) {
        timestamp = ISO8601DateFormatter().string(from: fix.timestamp)
        latitude = fix.latitude
        longitude = fix.longitude
        altitude_m = fix.altitude
        hdop = fix.hdop
        speed_kmh = fix.speedKmh
        satellites = fix.satellites
    }
}

struct LocalAgentTraffic: Encodable {
    let module: String
    let month_received: UInt64
    let month_sent: UInt64
    let days: [LocalAgentTrafficDay]
}

struct LocalAgentTrafficDay: Encodable {
    let day: String
    let received: UInt64
    let sent: UInt64
}

struct LocalAgentDiagnostics: Encodable {
    struct Check: Encodable { let name: String; let ok: Bool; let detail: String }
    struct Cell: Encodable {
        let technology: String?; let band: String?; let earfcn: String?; let cell_id: String?
        let pci: String?; let tac: String?; let rsrp: Int?; let rsrq: Int?; let sinr: Int?; let raw: String
    }
    let module: String
    let interface: String?
    let default_route_interface: String?
    let checks: [Check]
    let serving_cell: Cell?
    let pdp_contexts: String?

    init(module: CellularModuleSummary, result: ModuleDiagnostics) {
        self.module = module.id.rawValue
        interface = module.network.bsdName
        default_route_interface = result.defaultRouteInterface
        checks = result.checks.map { Check(name: $0.name, ok: $0.ok, detail: $0.detail) }
        serving_cell = result.servingCell.map {
            Cell(technology: $0.technology, band: $0.band, earfcn: $0.earfcn, cell_id: $0.cellID,
                 pci: $0.physicalCellID, tac: $0.tac, rsrp: $0.rsrp, rsrq: $0.rsrq, sinr: $0.sinr, raw: $0.raw)
        }
        pdp_contexts = result.pdpContexts
    }
}
