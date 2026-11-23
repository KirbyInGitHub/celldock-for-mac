import Foundation
import CellDockNetworkIPC

/// Loads or clears the pf anchor that keeps ordinary apps off the cellular
/// interfaces.
///
/// The anchor lives under `com.apple/`, which the stock /etc/pf.conf already
/// evaluates, so the system ruleset is never rewritten. pf is enabled with a
/// reference token (`pfctl -E`) and released with `pfctl -X`, which leaves pf
/// running if anything else on the Mac also enabled it. pf rules do not
/// survive a reboot, so the last request is kept on disk and the helper, which
/// launchd starts at boot, loads it again before anyone logs in.
final class CellularLockdownManager {
    static let anchor = "com.apple/celldock.lockdown"

    private let tokenURL = URL(
        fileURLWithPath: "/Library/Application Support/CellDock/pf-lockdown-token"
    )
    private let requestURL = URL(
        fileURLWithPath: "/Library/Application Support/CellDock/pf-lockdown.json"
    )

    /// Re-applies the saved lockdown. Called once when the helper starts.
    func restoreSavedLockdown() -> (CellDockNetworkResultCode, String)? {
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(CellularLockdownRequest.self, from: data),
              request.isValid, request.enabled, !request.interfaces.isEmpty else {
            return nil
        }
        return apply(request)
    }

    func apply(_ request: CellularLockdownRequest) -> (CellDockNetworkResultCode, String) {
        guard request.enabled, !request.interfaces.isEmpty else {
            return disable()
        }
        let rules = Self.rules(for: request.interfaces)
        let load = run(["-a", Self.anchor, "-f", "-"], input: rules)
        guard load.status == 0 else {
            return (.failure, "pf 规则加载失败：\(load.output)")
        }
        let enable = run(["-E"])
        guard enable.status == 0, let token = Self.token(in: enable.output) else {
            return (.failure, "无法启用 pf：\(enable.output)")
        }
        if let previous = storedToken(), previous != token {
            _ = run(["-X", previous])
        }
        storeToken(token)
        saveRequest(request)
        return (.success, "已限制 \(request.interfaces.joined(separator: ", "))：只允许 VPN 和系统服务出网。")
    }

    private func disable() -> (CellDockNetworkResultCode, String) {
        let flush = run(["-a", Self.anchor, "-F", "rules"])
        if let token = storedToken() {
            _ = run(["-X", token])
            try? FileManager.default.removeItem(at: tokenURL)
        }
        try? FileManager.default.removeItem(at: requestURL)
        guard flush.status == 0 else {
            return (.failure, "pf 规则清除失败：\(flush.output)")
        }
        return (.success, "已取消蜂窝网络限制。")
    }

    /// Outbound only. Replies to allowed connections pass through pf state;
    /// inbound traffic is left alone because it cannot leak anything.
    static func rules(for interfaces: [String]) -> String {
        let list = "{ " + interfaces.joined(separator: " ") + " }"
        return """
        pass out quick on \(list) inet proto udp from any port 68 to any port 67
        pass out quick on \(list) inet6 proto icmp6 all
        pass out quick on \(list) proto { tcp, udp } all user root keep state
        block drop out quick on \(list) all

        """
    }

    static func token(in output: String) -> String? {
        guard let range = output.range(of: #"Token\s*:\s*([0-9]+)"#, options: .regularExpression) else {
            return nil
        }
        return output[range].split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces)
    }

    private func storedToken() -> String? {
        guard let value = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            value.allSatisfy(\.isNumber), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func saveRequest(_ request: CellularLockdownRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        try? FileManager.default.createDirectory(
            at: requestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try? data.write(to: requestURL, options: .atomic)
    }

    private func storeToken(_ token: String) {
        try? FileManager.default.createDirectory(
            at: tokenURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
    }

    private func run(_ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}
