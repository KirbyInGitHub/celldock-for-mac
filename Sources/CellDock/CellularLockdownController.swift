import Foundation
import CellDockNetworkIPC

/// "Cellular only through Tailscale": keeps ordinary apps off the modules'
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

    private let client = NetworkHelperClient()
    private var interfaces: [String] = []
    private var appliedInterfaces: [String]?

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
