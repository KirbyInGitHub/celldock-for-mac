import AppKit
import Combine
import Foundation
import Security

@MainActor
final class LocalCallAPIController: ObservableObject {
    static let endpoint = "http://127.0.0.1:7576"
    private static let enabledKey = "LocalCallAPIEnabled.v1"
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    private weak var appState: AppState?
    private var server: LocalCallAPIServer?
    private var generation: UUID?
    private var token: String?
    private let idempotency = LocalAgentIdempotencyStore()

    init(appState: AppState) { self.appState = appState }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard isEnabled, server == nil, !AppTerminationCoordinator.shared.isTerminationPending else { return }
        error = nil
        do {
            let token = try LocalCallAPICredentialStore.loadOrCreate()
            self.token = token
            let generation = UUID()
            self.generation = generation
            let server = LocalCallAPIServer(token: token) { [weak self] command, completion in
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
                case .status, .modules, .messages, .sendSMS, .at: break
                }
            }
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
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        generation = nil
        server?.stop()
        server = nil
        token = nil
        isRunning = false
        error = nil
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

private enum LocalCallAPICredentialStore {
    static func loadOrCreate() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.celldock.mac.local-call-api",
            kSecAttrAccount as String: "bearer-token",
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new } as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty { return token }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw keychainError(randomStatus) }
        let token = Data(bytes).base64EncodedString()
        let added = SecItemAdd(query.merging([
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
        return token
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        ])
    }
}
