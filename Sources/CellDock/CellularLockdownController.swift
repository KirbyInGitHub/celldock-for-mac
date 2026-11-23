import Foundation
import CellDockNetworkIPC
import SystemConfiguration

/// Where the Mac's traffic leaves right now, as far as cellular is concerned.
enum CellularEgress: Equatable {
    case unknown
    /// Wi-Fi or Ethernet carries traffic; cellular is idle.
    case other(String)
    /// The module is the active link and a VPN tunnel holds the default route.
    case cellularViaTunnel(String)
    /// The module is the active link and also the default route.
    case cellularDirect(String)
}

/// "Cellular only through VPN": keeps ordinary apps off the modules'
/// network interfaces so they cannot fall back to the cellular link while a
/// VPN exit node is down or reconnecting. The privileged helper enforces it
/// with a pf anchor; this controller remembers the choice and re-applies it
/// when the set of module interfaces changes or CellDock starts.
@MainActor
final class CellularLockdownController: ObservableObject {
    private static let enabledKey = "CellDock.cellularLockdownEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isApplying = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var egress: CellularEgress = .unknown

    private let client = NetworkHelperClient()
    private var interfaces: [String] = []
    private var appliedInterfaces: [String]?
    private var egressTimer: Timer?
    private var egressCheckInFlight = false

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        apply(installKind: .userInitiated)
    }

    /// Called with every module status update. Applies only on a change.
    func updateInterfaces(_ names: [String]) {
        let sorted = Array(Set(names.filter(CellularLockdownRequest.isInterfaceName))).sorted()
        guard sorted != interfaces else { return }
        interfaces = sorted
        if isEnabled, !sorted.isEmpty, sorted != appliedInterfaces {
            apply(installKind: .automatic)
        }
        updateEgressMonitoring()
    }

    /// True when the lockdown leaves ordinary apps with no way out: cellular is
    /// the active link but no VPN tunnel carries the default route.
    var isBlockingAllTraffic: Bool {
        guard isEnabled, case .cellularDirect = egress else { return false }
        return true
    }

    // MARK: - Egress

    private func updateEgressMonitoring() {
        if interfaces.isEmpty {
            egressTimer?.invalidate()
            egressTimer = nil
            egress = .unknown
            return
        }
        guard egressTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        egressTimer = timer
        checkEgress()
    }

    private func checkEgress() {
        guard !egressCheckInFlight else { return }
        egressCheckInFlight = true
        let modules = Set(interfaces)
        Task.detached(priority: .utility) {
            let result = Self.currentEgress(moduleInterfaces: modules)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.egressCheckInFlight = false
                let wasBlocking = self.isBlockingAllTraffic
                self.egress = result
                if self.isBlockingAllTraffic, !wasBlocking {
                    NotificationService.shared.postNetworkNotice(
                        identifier: "cellular-lockdown-blocked",
                        title: L10n.tr("蜂窝网络没有 VPN 出口"),
                        body: L10n.tr("已开启“蜂窝只走 VPN”，但没有 VPN 承载流量，普通 App 现在无法上网。")
                    )
                }
            }
        }
    }

    /// The physical link is the first service in the user's service order that
    /// is not a tunnel and has an IPv4 router. The system's primary interface
    /// cannot be used for this: with a Tailscale exit node it is the tunnel.
    /// The default route then shows whether a tunnel sits on top.
    nonisolated private static func currentEgress(moduleInterfaces: Set<String>) -> CellularEgress {
        guard let store = SCDynamicStoreCreate(nil, "CellDock.egress" as CFString, nil, nil),
              let underlay = physicalInterface(store) else {
            return .unknown
        }
        guard moduleInterfaces.contains(underlay) else { return .other(underlay) }
        let route = defaultRouteInterface() ?? underlay
        if isTunnel(route) {
            return .cellularViaTunnel(route)
        }
        return .cellularDirect(underlay)
    }

    nonisolated private static func isTunnel(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    nonisolated private static func physicalInterface(_ store: SCDynamicStore) -> String? {
        let order = (SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString)
            as? [String: Any])?["ServiceOrder"] as? [String] ?? []
        guard let keys = SCDynamicStoreCopyKeyList(
            store, "State:/Network/Service/[^/]+/IPv4" as CFString
        ) as? [String] else { return nil }
        var links: [(service: String, interface: String)] = []
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = value["InterfaceName"] as? String,
                  value["Router"] != nil,
                  !isTunnel(interface) else { continue }
            let service = key.split(separator: "/").dropFirst(3).first.map(String.init) ?? ""
            links.append((service, interface))
        }
        let rank = { (service: String) in order.firstIndex(of: service) ?? Int.max }
        return links.min { rank($0.service) < rank($1.service) }?.interface
    }

    nonisolated private static func defaultRouteInterface() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces)
    }

    private func apply(installKind: NetworkHelperInstallRequestKind) {
        if isEnabled && interfaces.isEmpty {
            message = L10n.tr("连接模组后生效。")
            error = nil
            return
        }
        let request = CellularLockdownRequest(enabled: isEnabled, interfaces: interfaces)
        isApplying = true
        client.setCellularLockdown(request, installKind: installKind) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isApplying = false
                switch result {
                case let .success(text):
                    self.appliedInterfaces = request.enabled ? request.interfaces : nil
                    self.message = text
                    self.error = nil
                case let .failure(failure):
                    self.appliedInterfaces = nil
                    self.message = nil
                    self.error = failure.localizedDescription
                }
            }
        }
    }
}
