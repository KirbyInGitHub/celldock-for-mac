import Foundation

struct LocalCallAPIStatus: Encodable {
    let phase: String
    let moduleID: String?
    let number: String?
    let audioActive: Bool
    let muted: Bool
    let isChangingCall: Bool
    let lastError: String?
    let lastEndReason: String?
    let lastEndEvidence: CallEndEvidence?

    /// The app labels a generic release as the other side hanging up; the
    /// API only states what the modem reported, so it says unknown.
    static func reportedReason(_ reason: CallEndReason) -> CallEndReason {
        reason == .remoteHangup ? .unknown : reason
    }

    init(call: CallSnapshot, isChangingCall: Bool) {
        phase = call.phase.rawValue
        moduleID = call.moduleID?.rawValue
        number = call.number
        audioActive = call.audioActive
        muted = call.muted
        self.isChangingCall = isChangingCall
        lastError = call.lastError
        lastEndReason = call.lastEndReason.map(Self.reportedReason)?.rawValue
        lastEndEvidence = call.lastEndEvidence
    }
}

enum LocalCallAPICommand: Equatable {
    case status
    case dial(String)
    case answer
    case hangUp
    // Agent endpoints, see LocalAgentAPI.swift.
    case modules
    case messages(LocalAgentMessageQuery)
    case sendSMS(LocalAgentSMSRequest)
    case at(LocalAgentATRequest)
    case gnss
    case setGNSS(enabled: Bool, moduleID: String?)
    case traffic(days: Int)
    case diagnose(moduleID: String?)
}

struct LocalCallAPIResponse {
    let status: Int
    let body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> Self {
        Self(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> Self {
        json(["error": message], status: status)
    }

    var wireData: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
                      409: "Conflict", 413: "Content Too Large", 415: "Unsupported Media Type",
                      503: "Service Unavailable"][status] ?? "Error"
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        result.append(body)
        return result
    }
}

struct LocalCallAPIHTTPError: Error {
    let status: Int
    let message: String
}

/// A deliberately small HTTP/1.1 subset: one bounded request per connection,
/// explicit body length, no browser origins, chunking, or pipelining.
enum LocalCallAPIProtocol {
    static let headerLimit = 8192
    static let bodyLimit = 4096

    static func decode(_ data: Data, token: String, port: UInt16,
                       host: String = "127.0.0.1") throws -> LocalCallAPICommand? {
        func fail(_ status: Int, _ message: String) throws -> Never {
            throw LocalCallAPIHTTPError(status: status, message: message)
        }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > headerLimit { try fail(413, "Headers too large") }
            return nil
        }
        guard boundary.upperBound <= headerLimit else { try fail(413, "Headers too large") }
        guard let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            try fail(400, "Invalid HTTP headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else { try fail(400, "Expected HTTP/1.1") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { try fail(400, "Invalid header") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  headers[name] == nil else { try fail(400, "Invalid or duplicate header") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "\(host):\(port)" else { try fail(403, "Invalid Host") }
        guard headers["origin"] == nil else { try fail(403, "Browser origins are not supported") }
        guard !token.isEmpty, headers["authorization"] == "Bearer \(token)" else {
            try fail(401, "Bearer token required")
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            try fail(400, "Transfer-Encoding and Expect are not supported")
        }
        let length: Int
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(value) else { try fail(400, "Invalid Content-Length") }
            length = parsed
        } else {
            length = 0
        }
        guard length <= bodyLimit else { try fail(413, "Body too large") }
        let expected = boundary.upperBound + length
        guard data.count >= expected else { return nil }
        guard data.count == expected else { try fail(400, "Pipelining is not supported") }
        let target = first[1]
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let query = LocalAgentAPIRoutes.queryItems(target)
        let getRoutes = ["/api/calls/status", "/api/modules", "/api/sms", "/api/gnss", "/api/traffic"]
        let postRoutes = ["/api/calls/dial", "/api/calls/answer", "/api/calls/hangup",
                          "/api/sms/send", "/api/at", "/api/gnss", "/api/diagnostics"]
        guard getRoutes.contains(path) || postRoutes.contains(path) else { try fail(404, "Unknown endpoint") }
        // Only the list endpoints take a query string.
        guard target == path || ["/api/sms", "/api/traffic"].contains(path) else {
            try fail(404, "Unknown endpoint")
        }
        let isGET = first[0] == "GET"
        guard (isGET && getRoutes.contains(path)) || (first[0] == "POST" && postRoutes.contains(path)) else {
            try fail(405, "Method not allowed")
        }
        if isGET {
            guard length == 0 else { try fail(400, "Unexpected body") }
            switch path {
            case "/api/modules": return .modules
            case "/api/sms":
                do { return .messages(try LocalAgentMessageQuery(query: query)) }
                catch let error as LocalAgentAPIRequestError { try fail(400, error.message) }
            case "/api/gnss": return .gnss
            case "/api/traffic":
                let days = query["days"].flatMap(Int.init) ?? 30
                guard (1...400).contains(days) else { try fail(400, "days must be 1...400") }
                return .traffic(days: days)
            default: return .status
            }
        }
        guard headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else {
            try fail(415, "Content-Type must be application/json")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data[boundary.upperBound...])),
              let body = object as? [String: Any] else { try fail(400, "Expected a JSON object") }
        switch path {
        case "/api/calls/dial":
            guard Set(body.keys) == ["number"], let raw = body["number"] as? String,
                  let number = CallATParser.normalizedDialNumber(raw), number.count <= 32 else {
                try fail(400, "Expected number: up to 32 digits with an optional leading +")
            }
            return .dial(number)
        case "/api/sms/send":
            do { return .sendSMS(try LocalAgentSMSRequest(body: body)) }
            catch let error as LocalAgentAPIRequestError { try fail(400, error.message) }
        case "/api/at":
            do { return .at(try LocalAgentATRequest(body: body)) }
            catch let error as LocalAgentAPIRequestError { try fail(400, error.message) }
        case "/api/gnss":
            guard Set(body.keys).isSubset(of: ["enabled", "module"]), let enabled = body["enabled"] as? Bool else {
                try fail(400, "Expected {\"enabled\": true|false, \"module\"?}")
            }
            do { return .setGNSS(enabled: enabled, moduleID: try LocalAgentAPIRoutes.moduleID(body["module"])) }
            catch let error as LocalAgentAPIRequestError { try fail(400, error.message) }
        case "/api/diagnostics":
            guard Set(body.keys).isSubset(of: ["module"]) else { try fail(400, "Allowed keys: module") }
            do { return .diagnose(moduleID: try LocalAgentAPIRoutes.moduleID(body["module"])) }
            catch let error as LocalAgentAPIRequestError { try fail(400, error.message) }
        default:
            guard body.isEmpty else { try fail(400, "Expected an empty JSON object") }
            return path == "/api/calls/answer" ? .answer : .hangUp
        }
    }
}
