import Foundation
import Security

// `celldock`: JSON command line for the CellDock local API.
// Talks only to http://127.0.0.1:7576 with the local API bearer token; every
// capability is still checked by CellDock against the scopes in Settings.

let endpoint = "http://127.0.0.1:7576"
let version = "1.0.0"

struct CLIError: Error {
    let message: String
    var status: Int? = nil
    var requiredScope: String? = nil
}

// MARK: - Output

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func succeed(_ command: String, _ data: Any, extra: [String: Any] = [:]) -> Never {
    var object: [String: Any] = ["ok": true, "command": command, "data": data]
    object.merge(extra) { _, new in new }
    emit(object)
    exit(0)
}

func fail(_ command: String, _ error: CLIError) -> Never {
    var detail: [String: Any] = ["message": error.message]
    if let status = error.status { detail["status"] = status }
    if let scope = error.requiredScope { detail["required_scope"] = scope }
    emit(["ok": false, "command": command, "error": detail])
    exit(error.status == 403 ? 3 : 1)
}

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) throws {
        let valueOptions: Set<String> = ["--to", "--message", "--message-file", "--request-id",
                                         "--module", "--limit", "--id", "--number", "--dir"]
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if valueOptions.contains(item) {
                guard index + 1 < raw.count else { throw CLIError(message: "\(item) needs a value") }
                options[item] = raw[index + 1]
                index += 2
            } else if item.hasPrefix("--") {
                flags.insert(item)
                index += 1
            } else {
                positional.append(item)
                index += 1
            }
        }
    }

    func require(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else { throw CLIError(message: "\(name) is required") }
        return value
    }
}

// MARK: - Token and HTTP

func loadToken() throws -> String {
    if let token = ProcessInfo.processInfo.environment["CELLDOCK_API_TOKEN"], !token.isEmpty {
        return token
    }
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.celldock.mac.local-call-api",
        kSecAttrAccount as String: "bearer-token",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data,
          let token = String(data: data, encoding: .utf8), !token.isEmpty else {
        throw CLIError(message: "No local API token. Enable CellDock Settings → Local call API, or set CELLDOCK_API_TOKEN.")
    }
    return token
}

func request(_ method: String, _ path: String, body: [String: Any]? = nil,
             timeout: TimeInterval = 20) throws -> Any {
    let token = try loadToken()
    guard let url = URL(string: endpoint + path) else { throw CLIError(message: "Bad path \(path)") }
    var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
    urlRequest.httpMethod = method
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpAdditionalHeaders = [:]
    let session = URLSession(configuration: configuration)

    // The semaphore orders the single write before the read.
    final class Box: @unchecked Sendable { var result: Result<(Data, HTTPURLResponse), Error>? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: urlRequest) { data, response, error in
        if let error {
            box.result = .failure(error)
        } else if let http = response as? HTTPURLResponse {
            box.result = .success((data ?? Data(), http))
        } else {
            box.result = .failure(CLIError(message: "No HTTP response"))
        }
        done.signal()
    }.resume()
    done.wait()

    switch box.result {
    case .failure(let error as CLIError)?:
        throw error
    case .failure(let error as URLError)? where error.code == .cannotConnectToHost:
        throw CLIError(message: "CellDock is not running, or its Local call API is off")
    case .failure(let error as URLError)? where error.code == .timedOut:
        throw CLIError(message: "Timed out; read state before retrying a change")
    case .failure(let error)?:
        throw CLIError(message: error.localizedDescription)
    case .success(let (data, http))?:
        let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let object = json as? [String: Any]
            throw CLIError(message: object?["error"] as? String ?? object?["detail"] as? String
                               ?? "HTTP \(http.statusCode)",
                           status: http.statusCode,
                           requiredScope: object?["required_scope"] as? String)
        }
        return json
    case nil:
        throw CLIError(message: "No response")
    }
}

func query(_ items: [(String, String?)]) -> String {
    var components = URLComponents()
    components.queryItems = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    return components.percentEncodedQuery.map { "?" + $0 } ?? ""
}

/// Mutations print a plan with --dry-run, and run only with --yes.
func confirmMutation(_ command: String, _ args: Arguments, plan: [String: Any]) {
    if args.flags.contains("--dry-run") {
        succeed(command, plan, extra: ["dry_run": true])
    }
    guard args.flags.contains("--yes") else {
        fail(command, CLIError(message: "This changes state. Run with --dry-run first, then repeat with --yes."))
    }
}

// MARK: - Commands

let usage = """
celldock \(version) — JSON CLI for CellDock (local API at \(endpoint))

  celldock status                          modules + current call
  celldock modules                         modules, SIM, signal, network
  celldock sms list [--limit N] [--module ID] [--unread]
  celldock sms get --id ID
  celldock sms send --to NUMBER (--message TEXT | --message-file PATH)
                    --request-id ID [--module ID] (--dry-run | --yes)
  celldock at "AT+CSQ" [--module ID]       queries (ending in ?) run directly
  celldock at "AT+CFUN=1,1" (--dry-run | --yes)
  celldock call status
  celldock call dial --number NUMBER (--dry-run | --yes)
  celldock call answer (--dry-run | --yes)
  celldock call hangup
  celldock skill export                    print the agent skill (SKILL.md)
  celldock skill install [--dir DIR]       default ~/.claude/skills/celldock

Output is one JSON object: {"ok", "command", "data" | "error"}.
Exit codes: 0 ok, 1 error, 2 usage, 3 scope disabled in CellDock Settings.
"""

let raw = Array(CommandLine.arguments.dropFirst())
if raw.isEmpty || raw.first == "help" || raw.contains("--help") || raw.contains("-h") {
    print(usage)
    exit(raw.isEmpty ? 2 : 0)
}
if raw.first == "--version" || raw.first == "version" {
    succeed("version", ["version": version, "endpoint": endpoint])
}

let args: Arguments
do { args = try Arguments(raw) } catch let error as CLIError { fail("usage", error) } catch { exit(2) }
let group = args.positional.first ?? ""
let action = args.positional.dropFirst().first ?? ""
let name = action.isEmpty ? group : "\(group).\(action)"

do {
    switch (group, action) {
    case ("status", _):
        let modules = try request("GET", "/api/modules")
        let call = try request("GET", "/api/calls/status")
        succeed("status", ["modules": modules, "call": call])

    case ("modules", _):
        succeed("modules", try request("GET", "/api/modules"))

    case ("sms", "list"):
        let path = "/api/sms" + query([("limit", args.options["--limit"]), ("module", args.options["--module"]),
                                       ("unread", args.flags.contains("--unread") ? "1" : nil)])
        succeed(name, try request("GET", path))

    case ("sms", "get"):
        let id = try args.require("--id")
        let list = try request("GET", "/api/sms" + query([("id", id)])) as? [Any]
        succeed(name, list?.first ?? NSNull())

    case ("sms", "send"):
        let to = try args.require("--to")
        let requestID = try args.require("--request-id")
        let message: String
        if let path = args.options["--message-file"] {
            message = try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .newlines)
        } else {
            message = try args.require("--message")
        }
        var body: [String: Any] = ["to": to, "body": message, "request_id": requestID]
        if let module = args.options["--module"] { body["module"] = module }
        confirmMutation(name, args, plan: ["method": "POST", "path": "/api/sms/send", "body": body,
                                           "characters": message.count])
        succeed(name, try request("POST", "/api/sms/send", body: body, timeout: 120))

    case ("at", _):
        guard !action.isEmpty else { throw CLIError(message: "Usage: celldock at \"AT+CSQ\"") }
        let command = args.positional.dropFirst().joined(separator: " ")
        var body: [String: Any] = ["command": command]
        if let module = args.options["--module"] { body["module"] = module }
        let isQuery = command.trimmingCharacters(in: .whitespaces).hasSuffix("?")
        if !isQuery || args.flags.contains("--dry-run") {
            confirmMutation("at", args, plan: ["method": "POST", "path": "/api/at", "body": body,
                                               "note": "Non-query AT commands may change the module or SIM."])
        }
        succeed("at", try request("POST", "/api/at", body: body, timeout: 200))

    case ("call", "status"):
        succeed(name, try request("GET", "/api/calls/status"))

    case ("call", "dial"):
        let number = try args.require("--number")
        confirmMutation(name, args, plan: ["method": "POST", "path": "/api/calls/dial",
                                           "body": ["number": number]])
        succeed(name, try request("POST", "/api/calls/dial", body: ["number": number], timeout: 100))

    case ("call", "answer"):
        confirmMutation(name, args, plan: ["method": "POST", "path": "/api/calls/answer"])
        succeed(name, try request("POST", "/api/calls/answer", body: [:], timeout: 100))

    case ("call", "hangup"):
        // Hanging up is always a safe exit and needs no confirmation.
        succeed(name, try request("POST", "/api/calls/hangup", body: [:], timeout: 100))

    case ("skill", "export"):
        print(skillMarkdown)
        exit(0)

    case ("skill", "install"):
        let dir = args.options["--dir"].map { ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/skills/celldock")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("SKILL.md")
        try skillMarkdown.write(toFile: path, atomically: true, encoding: .utf8)
        succeed(name, ["path": path])

    default:
        fail("usage", CLIError(message: "Unknown command. Run `celldock help`."))
    }
} catch let error as CLIError {
    fail(name, error)
} catch {
    fail(name, CLIError(message: error.localizedDescription))
}
