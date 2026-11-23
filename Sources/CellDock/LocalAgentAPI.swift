import CellDockNetworkIPC
import Foundation

// Endpoints that let the `celldock` CLI and AI agents read
// modules and SMS, send SMS and run AT commands through the local API.
// Every endpoint shares the local API's loopback listener and bearer token;
// each capability is additionally gated by a scope the user turns on in
// Settings, so enabling the call API alone grants nothing new.

struct LocalAgentAPIRequestError: Error {
    let message: String
}

enum LocalAgentAPIScope: String, CaseIterable, Identifiable {
    case modulesRead = "modules.read"
    case smsRead = "sms.read"
    case smsSend = "sms.send"
    case atRead = "at.read"
    case atWrite = "at.write"

    var id: String { rawValue }

    private var defaultsKey: String { "LocalAgentAPIScope.\(rawValue).v1" }

    /// Reads default on, actions default off.
    var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: defaultsKey) != nil else {
                return self == .modulesRead || self == .smsRead || self == .atRead
            }
            return defaults.bool(forKey: defaultsKey)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .modulesRead: return L10n.tr("读取模组与网络状态")
        case .smsRead: return L10n.tr("读取短信")
        case .smsSend: return L10n.tr("发送短信")
        case .atRead: return L10n.tr("执行只读 AT 查询")
        case .atWrite: return L10n.tr("执行会修改模组的 AT 命令")
        }
    }
}

enum LocalAgentAPIRoutes {
    static func queryItems(_ target: String) -> [String: String] {
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] where result[item.name] == nil {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    static func moduleID(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String, !string.isEmpty, string.count <= 128 else {
            throw LocalAgentAPIRequestError(message: "module must be a non-empty string")
        }
        return string
    }
}

struct LocalAgentMessageQuery: Equatable {
    var limit = 20
    var moduleID: String?
    var id: String?
    var unreadOnly = false

    init(query: [String: String]) throws {
        let allowed: Set<String> = ["limit", "module", "id", "unread"]
        guard Set(query.keys).isSubset(of: allowed) else {
            throw LocalAgentAPIRequestError(message: "Unknown query parameter; allowed: limit, module, id, unread")
        }
        if let raw = query["limit"] {
            guard let value = Int(raw), (1...500).contains(value) else {
                throw LocalAgentAPIRequestError(message: "limit must be 1...500")
            }
            limit = value
        }
        moduleID = try LocalAgentAPIRoutes.moduleID(query["module"])
        id = query["id"].flatMap { $0.isEmpty ? nil : $0 }
        unreadOnly = query["unread"] == "1" || query["unread"] == "true"
    }
}

struct LocalAgentSMSRequest: Equatable {
    let to: String
    let body: String
    let moduleID: String?
    let requestID: String

    init(body json: [String: Any]) throws {
        guard Set(json.keys).isSubset(of: ["to", "body", "module", "request_id"]) else {
            throw LocalAgentAPIRequestError(message: "Allowed keys: to, body, module, request_id")
        }
        guard let to = json["to"] as? String,
              let normalized = CallATParser.normalizedDialNumber(to), normalized.count <= 32 else {
            throw LocalAgentAPIRequestError(message: "to: up to 32 digits with an optional leading +")
        }
        guard let body = json["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 1000 else {
            throw LocalAgentAPIRequestError(message: "body: 1...1000 characters")
        }
        guard let requestID = json["request_id"] as? String,
              (8...128).contains(requestID.count),
              requestID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0) }) else {
            throw LocalAgentAPIRequestError(message: "request_id: 8...128 of [A-Za-z0-9-_.:], stable across retries")
        }
        self.to = normalized
        self.body = body
        self.moduleID = try LocalAgentAPIRoutes.moduleID(json["module"])
        self.requestID = requestID
    }
}

struct LocalAgentATRequest: Equatable {
    let command: String
    let moduleID: String?
    let scope: LocalAgentAPIScope

    init(body json: [String: Any]) throws {
        guard Set(json.keys).isSubset(of: ["command", "module"]) else {
            throw LocalAgentAPIRequestError(message: "Allowed keys: command, module")
        }
        guard let raw = json["command"] as? String else {
            throw LocalAgentAPIRequestError(message: "command is required")
        }
        do {
            command = try ATConsoleCommandValidator.validate(raw)
        } catch {
            throw LocalAgentAPIRequestError(message: error.localizedDescription)
        }
        moduleID = try LocalAgentAPIRoutes.moduleID(json["module"])
        scope = LocalAgentATClassifier.isReadOnly(command) ? .atRead : .atWrite
    }
}

/// Decides whether an AT command only reads state. Anything not recognised
/// as a query needs the at.write scope, so unknown commands fail closed.
enum LocalAgentATClassifier {
    private static let bareReads: Set<String> = [
        "AT", "ATI", "ATI0", "AT+CSQ", "AT+CEER", "AT+CNUM", "AT+CIMI", "AT+CGSN", "AT+GSN",
        "AT+QCCID", "AT+CCID", "AT+ICCID", "AT+CGMR", "AT+GMR", "AT+CGMI", "AT+GMI",
        "AT+CGMM", "AT+GMM", "AT+QNWINFO", "AT+QSPN", "AT+QGMR", "AT+QCSQ", "AT+QRSRP",
        "AT+QRSRQ", "AT+QSINR", "AT+CGPADDR", "AT+CGCONTRDP", "AT+QLTS", "AT+CLAC",
    ]
    private static let readPrefixes = [
        "AT+QENG=\"SERVINGCELL\"", "AT+QENG=\"NEIGHBOURCELL\"", "AT+CGPADDR=", "AT+CGCONTRDP=",
        "AT+QLTS=", "AT+CEER=",
    ]

    static func isReadOnly(_ command: String) -> Bool {
        let compact = command.uppercased().replacingOccurrences(of: " ", with: "")
        if compact.hasSuffix("?") { return true }   // AT+X? and AT+X=?
        if bareReads.contains(compact) { return true }
        if readPrefixes.contains(where: { compact.hasPrefix($0) }) { return true }
        // AT+QCFG="name" with no value is the query form.
        if compact.hasPrefix("AT+QCFG=\""), !compact.contains(",") { return true }
        return false
    }
}

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
