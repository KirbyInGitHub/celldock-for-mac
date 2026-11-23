import Foundation

// Request parsing and scopes for the agent endpoints. Kept free of app state
// so the local API self-tests can compile it with the protocol.

struct LocalAgentAPIRequestError: Error {
    let message: String
}

enum LocalAgentAPIScope: String, CaseIterable, Identifiable {
    case modulesRead = "modules.read"
    case smsRead = "sms.read"
    case smsSend = "sms.send"
    case atRead = "at.read"
    case atWrite = "at.write"
    case gnssRead = "gnss.read"
    case gnssControl = "gnss.control"

    var id: String { rawValue }

    private var defaultsKey: String { "LocalAgentAPIScope.\(rawValue).v1" }

    /// Reads default on, actions default off.
    var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: defaultsKey) != nil else {
                return self == .modulesRead || self == .smsRead || self == .atRead || self == .gnssRead
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
        case .gnssRead: return L10n.tr("读取定位")
        case .gnssControl: return L10n.tr("开关 GNSS")
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
