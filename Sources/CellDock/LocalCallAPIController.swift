import AppKit
import Combine
import Foundation
import Security

@MainActor
final class LocalCallAPIController: ObservableObject {
    static let endpoint = "http://127.0.0.1:7576"
    private static let enabledKey = "LocalCallAPIEnabled.v1"
    private static let remoteKey = "LocalCallAPIRemoteTailscale.v1"
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var isRemoteEnabled = UserDefaults.standard.bool(forKey: remoteKey)
    /// http://<tailscale-ip>:7576 while the remote listener runs.
    @Published private(set) var remoteEndpoint: String?
    @Published private(set) var remoteError: String?
    private weak var appState: AppState?
    private var server: LocalCallAPIServer?
    private var remoteServer: LocalCallAPIServer?
    private var generation: UUID?
    private var token: String?
    private var handler: LocalCallAPIServer.Handler?
    private let idempotency = LocalAgentIdempotencyStore()

    init(appState: AppState) { self.appState = appState }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        isRemoteEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.remoteKey)
        if enabled { startRemote() } else { stopRemote() }
    }

    func start() {
        guard isEnabled, server == nil, !AppTerminationCoordinator.shared.isTerminationPending else { return }
        error = nil
        do {
            let token = try LocalCallAPICredentialStore.loadOrCreate()
            self.token = token
            LocalAgentCLIAccessFile.write(token: token, endpoint: Self.endpoint)
            let generation = UUID()
            self.generation = generation
            let handler: LocalCallAPIServer.Handler = { [weak self] command, completion in
                guard let self, self.generation == generation, self.isEnabled,
                      let appState = self.appState else {
                    completion(.error(503, "Local call API is stopped"))
                    return
                }
                if command == .status {
                    completion(.json(LocalCallAPIStatus(appState: appState)))
                    return
                }
                if self.handleAgentCommand(command, appState: appState, completion: completion) {
                    return
                }
                let completed: (ModemActionResult) -> Void = { result in
                    switch result {
                    case .success:
                        completion(.json(LocalCallAPIActionResponse(accepted: true,
                            call: LocalCallAPIStatus(appState: appState))))
                    case .failure(let message): completion(.error(409, message))
                    }
                }
                switch command {
                case .dial(let number): appState.dial(number, completion: completed)
                case .answer: appState.answerCall(completion: completed)
                case .hangUp: appState.hangUp(completion: completed)
                case .status, .modules, .messages, .sendSMS, .at, .gnss, .setGNSS, .traffic, .diagnose: break
                }
            }
            self.handler = handler
            let server = LocalCallAPIServer(token: token, handler: handler)
            self.server = server
            try server.start { [weak self] error in
                guard let self, self.generation == generation else { return }
                self.isRunning = error == nil
                self.error = error
                if error != nil {
                    self.server?.stop()
                    self.server = nil
                    self.generation = nil
                }
            }
            startRemote()
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        LocalAgentCLIAccessFile.remove()
        stopRemote()
        handler = nil
        generation = nil
        server?.stop()
        server = nil
        token = nil
        isRunning = false
        error = nil
    }

    private func startRemote() {
        guard isEnabled, isRemoteEnabled, remoteServer == nil, let token, let handler else { return }
        remoteError = nil
        guard let address = TailscaleAddress.local() else {
            remoteError = L10n.tr("没有找到这台 Mac 的 Tailscale 地址，请先连接 Tailscale。")
            return
        }
        let server = LocalCallAPIServer(token: token, host: address, handler: handler)
        remoteServer = server
        do {
            try server.start { [weak self] error in
                guard let self, self.remoteServer === server else { return }
                self.remoteEndpoint = error == nil ? "http://\(address):7576" : nil
                self.remoteError = error
                if error != nil {
                    server.stop()
                    self.remoteServer = nil
                }
            }
        } catch {
            remoteServer = nil
            remoteError = error.localizedDescription
        }
    }

    private func stopRemote() {
        remoteServer?.stop()
        remoteServer = nil
        remoteEndpoint = nil
        remoteError = nil
    }

    func copyToken() {
        guard isRunning, let token else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }
}

// MARK: - Agent endpoints

private extension LocalCallAPIController {
    /// Returns false for the original call commands so they keep their path.
    func handleAgentCommand(_ command: LocalCallAPICommand, appState: AppState,
                            completion: @escaping (LocalCallAPIResponse) -> Void) -> Bool {
        func denied(_ scope: LocalAgentAPIScope) -> Bool {
            guard !scope.isEnabled else { return false }
            completion(.json(["error": "Scope \(scope.rawValue) is off; enable it in CellDock Settings → Local API",
                              "required_scope": scope.rawValue], status: 403))
            return true
        }
        func resolve(_ raw: String?) -> CellularModuleID?? {
            guard let raw else { return .some(nil) }
            let id = CellularModuleID(rawValue: raw)
            guard appState.cellularModules.contains(where: { $0.id == id }) else {
                completion(.error(404, "Unknown module \(raw); list modules with GET /api/modules"))
                return nil
            }
            return .some(id)
        }

        switch command {
        case .status, .dial, .answer, .hangUp:
            return false

        case .modules:
            guard !denied(.modulesRead) else { return true }
            let modules = appState.cellularModules.map {
                LocalAgentModule($0, networkMode: appState.networkMode(for: $0.id))
            }
            completion(.json(modules))

        case .messages(let query):
            guard !denied(.smsRead) else { return true }
            var messages = appState.messages
            if let id = query.id {
                guard let message = messages.first(where: { $0.id == id }) else {
                    completion(.error(404, "No message with that id"))
                    return true
                }
                completion(.json([LocalAgentMessage(message)]))
                return true
            }
            if let module = query.moduleID { messages = messages.filter { $0.moduleID?.rawValue == module } }
            if query.unreadOnly { messages = messages.filter { !$0.isRead && !$0.isOutgoing } }
            messages.sort { $0.timestamp > $1.timestamp }
            completion(.json(messages.prefix(query.limit).map(LocalAgentMessage.init)))

        case .sendSMS(let request):
            guard !denied(.smsSend) else { return true }
            guard let resolved = resolve(request.moduleID) else { return true }
            switch idempotency.begin(request) {
            case .pending:
                completion(.error(409, "This request_id is still sending; check GET /api/sms before retrying"))
                return true
            case .conflict:
                completion(.error(409, "request_id was already used for a different message"))
                return true
            case .done(let result):
                completion(.json(result))
                return true
            case .new:
                break
            }
            appState.sendSMS(to: request.to, body: request.body, via: resolved) { [weak self] result in
                let moduleID = appState.resolvedCommunicationModuleID(resolved).rawValue
                let outcome: LocalAgentSMSSendResult
                switch result {
                case .success(let detail):
                    outcome = .init(request_id: request.requestID, module: moduleID, to: request.to,
                                    status: "sent", detail: detail, replayed: false)
                case let .failure(message, uncertain):
                    outcome = .init(request_id: request.requestID, module: moduleID, to: request.to,
                                    status: uncertain ? "uncertain" : "failed", detail: message, replayed: false)
                }
                self?.idempotency.finish(request, result: outcome)
                completion(.json(outcome, status: outcome.status == "failed" ? 409 : 200))
            }

        case .gnss:
            guard !denied(.gnssRead) else { return true }
            let gnss = appState.gnssController
            completion(.json(gnss.availableModules.map { module -> LocalAgentGNSSStatus in
                let state = gnss.state(for: module.id)
                var satellites: Int?
                if case .searching(let count) = state { satellites = count }
                return LocalAgentGNSSStatus(module: module.id.rawValue, enabled: gnss.isEnabled(module.id),
                                            state: state.apiValue, satellites_in_view: satellites,
                                            fix: gnss.lastFixes[module.id].map(LocalAgentGNSSFix.init))
            }))

        case let .setGNSS(enabled, rawModule):
            guard !denied(.gnssControl) else { return true }
            guard let resolved = resolve(rawModule) else { return true }
            let moduleID = appState.resolvedCommunicationModuleID(resolved)
            appState.gnssController.setEnabled(enabled, for: moduleID) { result in
                switch result {
                case .success:
                    completion(.json(["module": moduleID.rawValue, "enabled": enabled ? "true" : "false",
                                      "state": appState.gnssController.state(for: moduleID).apiValue]))
                case .failure(let message):
                    completion(.error(409, message))
                }
            }

        case .traffic(let days):
            guard !denied(.modulesRead) else { return true }
            let diagnostics = appState.networkDiagnosticsController
            completion(.json(diagnostics.availableModules.map { module in
                let month = diagnostics.monthTotal(for: module)
                return LocalAgentTraffic(
                    module: module.id.rawValue, month_received: month.received, month_sent: month.sent,
                    days: diagnostics.days(for: module, last: days).map {
                        LocalAgentTrafficDay(day: $0.day, received: $0.received, sent: $0.sent)
                    })
            }))

        case .diagnose(let rawModule):
            guard !denied(.modulesRead) else { return true }
            guard let resolved = resolve(rawModule) else { return true }
            let moduleID = appState.resolvedCommunicationModuleID(resolved)
            let diagnostics = appState.networkDiagnosticsController
            guard let module = diagnostics.availableModules.first(where: { $0.id == moduleID }) else {
                completion(.error(409, "The module is not connected"))
                return true
            }
            guard diagnostics.diagnostics[moduleID]?.isRunning != true else {
                completion(.error(409, "Diagnostics are already running for this module"))
                return true
            }
            diagnostics.runDiagnostics(for: module) {
                let result = diagnostics.diagnostics[moduleID] ?? ModuleDiagnostics()
                completion(.json(LocalAgentDiagnostics(module: module, result: result)))
            }

        case .at(let request):
            guard !denied(request.scope) else { return true }
            guard let resolved = resolve(request.moduleID) else { return true }
            guard !appState.isExecutingAT else {
                completion(.error(409, "Another AT command is running; retry shortly"))
                return true
            }
            guard !appState.moduleHasCall(resolved) else {
                completion(.error(409, "The module has an active call"))
                return true
            }
            let moduleID = appState.resolvedCommunicationModuleID(resolved).rawValue
            appState.executeAT(request.command, via: resolved) { result in
                completion(.json(LocalAgentATResult(module: moduleID, command: result.command,
                                                    ok: result.isSuccess, output: result.output,
                                                    error: result.error,
                                                    elapsed_ms: result.elapsedMilliseconds)))
            }
        }
        return true
    }
}

private struct LocalCallAPIActionResponse: Encodable {
    let accepted: Bool
    let call: LocalCallAPIStatus
}

private extension LocalCallAPIStatus {
    @MainActor init(appState: AppState) {
        self.init(call: appState.call, isChangingCall: appState.isChangingCall)
    }
}

/// The token lives in a 0600 file in the user's Application Support folder
/// rather than the Keychain: a self-signed build changes its code signature
/// on every rebuild, and the Keychain would ask for the login password again
/// each time. Delete the file (with the API off) to issue a new token.
private enum LocalCallAPICredentialStore {
    static var url: URL {
        AppDataDirectory.userApplicationSupport().appendingPathComponent("local-api-token")
    }

    static func loadOrCreate() throws -> String {
        let path = url.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
                  let data = FileManager.default.contents(atPath: path),
                  let token = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  token.count >= 32 else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                    NSLocalizedDescriptionKey: "\(path) must be a 0600 file owned by you; delete it to issue a new token."
                ])
            }
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw randomError(randomStatus) }
        let token = Data(bytes).base64EncodedString()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "Could not write \(path)"
            ])
        }
        return token
    }

    private static func randomError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Random generator error \(status)"
        ])
    }
}
