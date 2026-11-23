import Combine
import Foundation

/// Daily cellular data totals per module, from the ECM interface's byte
/// counters. Kept on this Mac only.
struct TrafficDay: Codable, Equatable, Identifiable {
    var id: String { "\(module)|\(day)" }
    let module: String          // IMEI when known, so totals follow the module across ports
    let day: String             // yyyy-MM-dd, local time
    var received: UInt64
    var sent: UInt64
}

struct ServingCellInfo: Equatable {
    var state: String?
    var technology: String?
    var duplex: String?
    var mcc: String?
    var mnc: String?
    var cellID: String?
    var physicalCellID: String?
    var earfcn: String?
    var band: String?
    var tac: String?
    var rsrp: Int?
    var rsrq: Int?
    var rssi: Int?
    var sinr: Int?
    var raw: String

    /// Parses AT+QENG="servingcell". LTE lines are broken into fields; other
    /// technologies keep the raw response.
    static func parse(_ output: String) -> ServingCellInfo? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("+QENG:") }) else { return nil }
        let raw = String(line)
        let fields = line.dropFirst("+QENG:".count)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        var info = ServingCellInfo(raw: raw)
        guard fields.count > 2 else { return info }
        info.state = fields[1]
        info.technology = fields[2]
        guard fields[2] == "LTE", fields.count >= 17 else { return info }
        info.duplex = fields[3]
        info.mcc = fields[4]
        info.mnc = fields[5]
        info.cellID = fields[6]
        info.physicalCellID = fields[7]
        info.earfcn = fields[8]
        info.band = fields[9]
        info.tac = fields[12]
        info.rsrp = Int(fields[13])
        info.rsrq = Int(fields[14])
        info.rssi = Int(fields[15])
        info.sinr = Int(fields[16])
        return info
    }
}

struct ConnectivityCheck: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let ok: Bool
    let detail: String
}

struct ModuleRadioState: Equatable {
    var bands: ModuleBandConfiguration?
    var scanMode: Int?
    var temperatures: [ModuleTemperature.Reading] = []
    var isBusy = false
    var message: String?
    var error: String?
}

struct ModuleDiagnostics: Equatable {
    var servingCell: ServingCellInfo?
    var pdpContexts: String?
    var defaultRouteInterface: String?
    var checks: [ConnectivityCheck] = []
    var checkedAt: Date?
    var isRunning = false
}

@MainActor
final class NetworkDiagnosticsController: ObservableObject {
    @Published private(set) var traffic: [TrafficDay] = []
    @Published private(set) var diagnostics: [CellularModuleID: ModuleDiagnostics] = [:]
    @Published private(set) var signalSamples: [SignalSample] = []
    @Published private(set) var radio: [CellularModuleID: ModuleRadioState] = [:]
    @Published private(set) var dataCapRevision = 0

    private weak var appState: AppState?
    private var timer: Timer?
    private var lastCounters: [String: NetworkInterfaceByteCounters] = [:]
    private var lastSave = Date.distantPast
    private var signalTimer: Timer?
    private var signalInFlight: Set<CellularModuleID> = []
    private var lastSignalSave = Date.distantPast
    private static let sampleInterval: TimeInterval = 5
    private static let signalInterval: TimeInterval = 60
    private static let signalRetention: TimeInterval = 7 * 24 * 3600

    init(appState: AppState) {
        self.appState = appState
        traffic = Self.loadTraffic()
        signalSamples = Self.loadSignal()
    }

    var availableModules: [CellularModuleSummary] {
        appState?.cellularModules.filter { $0.modem.isConnected } ?? []
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleTraffic() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let signalTimer = Timer(timeInterval: Self.signalInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSignal() }
        }
        RunLoop.main.add(signalTimer, forMode: .common)
        self.signalTimer = signalTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.sampleSignal() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        signalTimer?.invalidate()
        signalTimer = nil
        saveTraffic()
        saveSignal()
    }

    // MARK: - Traffic

    static func trafficKey(for module: CellularModuleSummary) -> String {
        module.modem.moduleIMEI.map { "imei:\($0)" } ?? module.id.rawValue
    }

    func days(for module: CellularModuleSummary, last count: Int = 30) -> [TrafficDay] {
        let key = Self.trafficKey(for: module)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let day = Self.dayString(date)
            return traffic.first { $0.module == key && $0.day == day }
                ?? TrafficDay(module: key, day: day, received: 0, sent: 0)
        }
    }

    func monthTotal(for module: CellularModuleSummary) -> (received: UInt64, sent: UInt64) {
        let key = Self.trafficKey(for: module)
        let prefix = String(Self.dayString(Date()).prefix(7))
        return traffic.filter { $0.module == key && $0.day.hasPrefix(prefix) }
            .reduce((UInt64(0), UInt64(0))) { ($0.0 + $1.received, $0.1 + $1.sent) }
    }

    func clearTraffic(for module: CellularModuleSummary) {
        let key = Self.trafficKey(for: module)
        traffic.removeAll { $0.module == key }
        saveTraffic()
    }

    private func sampleTraffic() {
        for module in availableModules {
            guard let interface = module.network.bsdName,
                  let current = NetworkInterfaceCounterReader.read(interfaceName: interface) else { continue }
            let counterKey = "\(module.id.rawValue)|\(interface)"
            defer { lastCounters[counterKey] = current }
            guard let previous = lastCounters[counterKey],
                  let rate = NetworkThroughputCalculator.rates(previous: previous, current: current) else { continue }
            let elapsed = current.uptime - previous.uptime
            let received = UInt64(max(0, rate.downloadBytesPerSecond * elapsed))
            let sent = UInt64(max(0, rate.uploadBytesPerSecond * elapsed))
            guard received > 0 || sent > 0 else { continue }
            let key = Self.trafficKey(for: module)
            let day = Self.dayString(Date())
            if let index = traffic.firstIndex(where: { $0.module == key && $0.day == day }) {
                traffic[index].received += received
                traffic[index].sent += sent
            } else {
                traffic.append(TrafficDay(module: key, day: day, received: received, sent: sent))
            }
        }
        if Date().timeIntervalSince(lastSave) > 60 { saveTraffic() }
        checkDataCaps()
    }

    // MARK: - Data cap

    private static func dataCapKey(_ trafficKey: String) -> String { "CellDock.dataCapGB.\(trafficKey)" }
    private static func dataCapAlertKey(_ trafficKey: String) -> String { "CellDock.dataCapAlert.\(trafficKey)" }

    /// Monthly plan allowance in GB, or nil when none is set.
    func dataCapGB(for module: CellularModuleSummary) -> Double? {
        _ = dataCapRevision
        let value = UserDefaults.standard.double(forKey: Self.dataCapKey(Self.trafficKey(for: module)))
        return value > 0 ? value : nil
    }

    func setDataCapGB(_ value: Double?, for module: CellularModuleSummary) {
        let key = Self.trafficKey(for: module)
        if let value, value > 0 {
            UserDefaults.standard.set(value, forKey: Self.dataCapKey(key))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.dataCapKey(key))
        }
        UserDefaults.standard.removeObject(forKey: Self.dataCapAlertKey(key))
        dataCapRevision += 1
        checkDataCaps()
    }

    /// Notifies once per month at 80% and once at 100% of the allowance.
    private func checkDataCaps() {
        let month = String(Self.dayString(Date()).prefix(7))
        for module in availableModules {
            guard let cap = dataCapGB(for: module) else { continue }
            let key = Self.trafficKey(for: module)
            let total = monthTotal(for: module)
            let used = Double(total.received + total.sent)
            let limit = cap * 1_073_741_824
            let level = used >= limit ? 100 : used >= limit * 0.8 ? 80 : 0
            guard level > 0 else { continue }
            let marker = "\(month):\(level)"
            let previous = UserDefaults.standard.string(forKey: Self.dataCapAlertKey(key)) ?? ""
            guard previous != marker, !(previous.hasPrefix(month) && previous.hasSuffix(":100")) else { continue }
            UserDefaults.standard.set(marker, forKey: Self.dataCapAlertKey(key))
            let usedText = NetworkSpeedFormatter.byteCount(UInt64(used))
            NotificationService.shared.postNetworkNotice(
                identifier: "data-cap-\(key)",
                title: level == 100 ? L10n.tr("本月蜂窝流量已用完") : L10n.tr("本月蜂窝流量已用 80%"),
                body: L10n.tr("%@ 本月已用 %@，套餐 %@ GB。", module.localizedDisplayName, usedText,
                              cap.formatted(.number.precision(.fractionLength(0...1))))
            )
        }
    }

    // MARK: - Signal history

    func signalHistory(for module: CellularModuleSummary, since: Date) -> [SignalSample] {
        let key = Self.trafficKey(for: module)
        return signalSamples.filter { $0.module == key && $0.timestamp >= since }
    }

    func clearSignalHistory(for module: CellularModuleSummary) {
        let key = Self.trafficKey(for: module)
        signalSamples.removeAll { $0.module == key }
        saveSignal()
    }

    /// Reads the serving cell once a minute so a weak or changing cell shows
    /// up later in the chart, even while this page is closed.
    private func sampleSignal() {
        guard let appState else { return }
        for module in availableModules where module.modem.registrationState.hasService {
            let moduleID = module.id
            guard !signalInFlight.contains(moduleID) else { continue }
            signalInFlight.insert(moduleID)
            let key = Self.trafficKey(for: module)
            appState.runFeatureAT("AT+QENG=\"servingcell\"", via: moduleID) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.signalInFlight.remove(moduleID)
                    guard let cell = ServingCellInfo.parse(result.output), let rsrp = cell.rsrp,
                          (-140 ... -44).contains(rsrp) else { return }
                    self.signalSamples.append(SignalSample(
                        module: key, timestamp: Date(), rsrp: rsrp, sinr: cell.sinr,
                        rsrq: cell.rsrq, band: cell.band, cellID: cell.cellID
                    ))
                    if Date().timeIntervalSince(self.lastSignalSave) > 600 { self.saveSignal() }
                }
            }
        }
    }

    private static var signalURL: URL {
        AppDataDirectory.userApplicationSupport().appendingPathComponent("signal-history.json")
    }

    private static func loadSignal() -> [SignalSample] {
        guard let data = try? Data(contentsOf: signalURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SignalSample].self, from: data)) ?? []
    }

    private func saveSignal() {
        lastSignalSave = Date()
        let cutoff = Date().addingTimeInterval(-Self.signalRetention)
        signalSamples.removeAll { $0.timestamp < cutoff }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(signalSamples) else { return }
        try? FileManager.default.createDirectory(
            at: Self.signalURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.signalURL, options: .atomic)
    }

    // MARK: - Bands, scan mode and temperature

    private static func originalBandsKey(_ trafficKey: String) -> String { "CellDock.originalLTEBands.\(trafficKey)" }

    /// The LTE bands the module allowed before CellDock first changed them.
    func originalBands(for module: CellularModuleSummary) -> Set<Int>? {
        UserDefaults.standard.string(forKey: Self.originalBandsKey(Self.trafficKey(for: module)))
            .flatMap(LTEBandMask.init(hex:))?.bands
    }

    func loadRadio(for module: CellularModuleSummary) {
        guard let appState else { return }
        let moduleID = module.id
        let key = Self.trafficKey(for: module)
        appState.runFeatureAT("AT+QCFG=\"band\"", via: moduleID) { [weak self] band in
            appState.runFeatureAT("AT+QCFG=\"nwscanmode\"", via: moduleID) { [weak self] scan in
                appState.runFeatureAT("AT+QTEMP", via: moduleID) { [weak self] temperature in
                    Task { @MainActor in
                        guard let self else { return }
                        var state = self.radio[moduleID] ?? ModuleRadioState()
                        state.bands = ModuleBandConfiguration.parse(band.output)
                        state.scanMode = ModuleScanMode.parse(scan.output)
                        state.temperatures = ModuleTemperature.parse(temperature.output)
                        if let bands = state.bands,
                           UserDefaults.standard.string(forKey: Self.originalBandsKey(key)) == nil {
                            UserDefaults.standard.set(bands.lte.hex, forKey: Self.originalBandsKey(key))
                        }
                        self.radio[moduleID] = state
                    }
                }
            }
        }
    }

    func setLTEBands(_ bands: Set<Int>, for module: CellularModuleSummary) {
        guard !bands.isEmpty, let current = radio[module.id]?.bands else { return }
        let command = current.writeCommand(lte: bands)
        let summary = bands.sorted().map { "B\($0)" }.joined(separator: " ")
        write(command, for: module, success: L10n.tr("已允许频段：%@。模组会重新搜网。", summary))
    }

    func setScanMode(_ mode: ModuleScanMode, for module: CellularModuleSummary) {
        write("AT+QCFG=\"nwscanmode\",\(mode.rawValue),1", for: module,
              success: L10n.tr("网络制式已设为%@。", mode.localizedTitle))
    }

    private func write(_ command: String, for module: CellularModuleSummary, success: String) {
        guard let appState, radio[module.id]?.isBusy != true else { return }
        let moduleID = module.id
        radio[moduleID, default: ModuleRadioState()].isBusy = true
        appState.runFeatureAT(command, via: moduleID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                var state = self.radio[moduleID] ?? ModuleRadioState()
                state.isBusy = false
                state.message = result.isSuccess ? success : nil
                state.error = result.isSuccess ? nil : (result.error ?? result.output)
                self.radio[moduleID] = state
                self.loadRadio(for: module)
            }
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static var trafficURL: URL {
        AppDataDirectory.userApplicationSupport().appendingPathComponent("traffic-history.json")
    }

    private static func loadTraffic() -> [TrafficDay] {
        guard let data = try? Data(contentsOf: trafficURL) else { return [] }
        return (try? JSONDecoder().decode([TrafficDay].self, from: data)) ?? []
    }

    private func saveTraffic() {
        lastSave = Date()
        // Keep about a year.
        let cutoff = Self.dayString(Calendar.current.date(byAdding: .day, value: -400, to: Date()) ?? Date())
        traffic.removeAll { $0.day < cutoff }
        guard let data = try? JSONEncoder().encode(traffic) else { return }
        try? FileManager.default.createDirectory(
            at: Self.trafficURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.trafficURL, options: .atomic)
    }

    // MARK: - Diagnostics

    func runDiagnostics(for module: CellularModuleSummary, completion: (() -> Void)? = nil) {
        guard let appState, diagnostics[module.id]?.isRunning != true else { return }
        var result = diagnostics[module.id] ?? ModuleDiagnostics()
        result.isRunning = true
        diagnostics[module.id] = result
        let moduleID = module.id
        let network = module.network

        appState.runFeatureAT("AT+QENG=\"servingcell\"", via: moduleID) { [weak self] cell in
            appState.runFeatureAT("AT+CGCONTRDP", via: moduleID) { [weak self] contexts in
                Task.detached(priority: .userInitiated) {
                    let route = Self.defaultRouteInterface()
                    let checks = Self.connectivityChecks(network: network)
                    await MainActor.run {
                        guard let self else { return }
                        var updated = self.diagnostics[moduleID] ?? ModuleDiagnostics()
                        updated.servingCell = ServingCellInfo.parse(cell.output)
                        updated.pdpContexts = contexts.isSuccess
                            ? contexts.output.replacingOccurrences(of: "\r", with: "")
                                .split(separator: "\n").filter { $0.hasPrefix("+CGCONTRDP") }
                                .joined(separator: "\n")
                            : contexts.error
                        updated.defaultRouteInterface = route
                        updated.checks = checks
                        updated.checkedAt = Date()
                        updated.isRunning = false
                        self.diagnostics[moduleID] = updated
                        completion?()
                    }
                }
            }
        }
    }

    nonisolated private static func defaultRouteInterface() -> String? {
        let output = run("/sbin/route", ["-n", "get", "default"], timeout: 5)
        return output.split(whereSeparator: \.isNewline)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }
            .map { $0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "" }
    }

    /// Each check is bound to the module's interface, so it tests the
    /// cellular path even while Wi-Fi or Ethernet is the default route.
    nonisolated private static func connectivityChecks(network: CellularNetworkStatus) -> [ConnectivityCheck] {
        guard let interface = network.bsdName, network.ipv4Address != nil || network.ipv6Address != nil else {
            return [ConnectivityCheck(name: L10n.tr("模组网卡"), ok: false,
                                      detail: L10n.tr("模组网卡没有 IP 地址。"))]
        }
        var checks: [ConnectivityCheck] = []

        checks.append(ping(name: L10n.tr("公网 IPv4（223.5.5.5）"), target: "223.5.5.5", interface: interface))

        if let dns = network.dnsServers.first {
            let started = Date()
            let output = run("/usr/bin/dig", ["-b", network.ipv4Address ?? "0.0.0.0", "@\(dns)",
                                              "+time=3", "+tries=1", "+short", "www.baidu.com"], timeout: 6)
            let ok = output.split(whereSeparator: \.isNewline).contains { !$0.isEmpty && !$0.hasPrefix(";") }
            checks.append(ConnectivityCheck(
                name: L10n.tr("运营商 DNS（%@）", dns), ok: ok,
                detail: ok ? milliseconds(since: started) : L10n.tr("没有应答")
            ))
        }

        checks.append(http(name: "HTTPS IPv4", url: "https://www.baidu.com", interface: interface, ipv6: false))
        if network.ipv6Address != nil {
            checks.append(http(name: "HTTPS IPv6", url: "https://ipv6.baidu.com", interface: interface, ipv6: true))
        }
        return checks
    }

    nonisolated private static func ping(name: String, target: String, interface: String) -> ConnectivityCheck {
        let output = run("/sbin/ping", ["-b", interface, "-c", "3", "-t", "6", "-q", target], timeout: 8)
        let loss = output.range(of: #"[\d.]+% packet loss"#, options: .regularExpression)
            .map { String(output[$0]).replacingOccurrences(of: " packet loss", with: "") }
            .map { $0.replacingOccurrences(of: ".0%", with: "%") }
        let average = output.range(of: #"= [\d.]+/([\d.]+)/"#, options: .regularExpression)
            .map { String(output[$0]).split(separator: "/")[1] }
        let ok = loss != nil && !(loss?.hasPrefix("100") ?? true)
        let detail = ok
            ? L10n.tr("平均 %@ ms，丢包 %@", String(average ?? "?"), loss ?? "")
            : L10n.tr("没有回应")
        return ConnectivityCheck(name: name, ok: ok, detail: detail)
    }

    nonisolated private static func http(name: String, url: String, interface: String, ipv6: Bool) -> ConnectivityCheck {
        let output = run("/usr/bin/curl", [ipv6 ? "-6" : "-4", "--interface", interface, "--noproxy", "*",
                                           "-s", "-o", "/dev/null", "-m", "8",
                                           "-w", "%{http_code} %{time_total}", url], timeout: 10)
        let parts = output.split(separator: " ")
        let code = parts.first.flatMap { Int($0) } ?? 0
        let seconds = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        let ok = (200..<400).contains(code)
        return ConnectivityCheck(name: name, ok: ok,
                                 detail: ok ? "HTTP \(code)，\(Int(seconds * 1000)) ms" : L10n.tr("连接失败"))
    }

    nonisolated private static func milliseconds(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000)) ms"
    }

    nonisolated private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return "" }
        if finished.wait(timeout: .now() + timeout) == .timedOut { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
