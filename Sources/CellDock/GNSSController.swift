import Combine
import CoreLocation
import Foundation

/// One position reported by the module's GNSS receiver (WGS-84).
struct GNSSFix: Codable, Equatable, Identifiable {
    var id: Date { timestamp }
    let moduleID: String
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let hdop: Double?
    let speedKmh: Double?
    let course: Double?
    let satellites: Int?
    let fixDimension: Int?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Coordinate for Apple Maps, which uses GCJ-02 inside mainland China.
    var mapCoordinate: CLLocationCoordinate2D {
        ChinaMapCoordinate.gcj02(fromWGS84: coordinate)
    }
}

enum GNSSModuleState: Equatable {
    case off
    case starting
    case searching(satellitesInView: Int?)
    case fixed
    case unsupported(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .searching, .fixed: return true
        default: return false
        }
    }

    var localizedTitle: String {
        switch self {
        case .off: return L10n.tr("已关闭")
        case .starting: return L10n.tr("正在启动")
        case .searching(let count):
            if let count { return L10n.tr("正在搜星（可见 %lld 颗）", Int64(count)) }
            return L10n.tr("正在搜星")
        case .fixed: return L10n.tr("已定位")
        case .unsupported(let message), .failed(let message): return message
        }
    }

    var apiValue: String {
        switch self {
        case .off: return "off"
        case .starting: return "starting"
        case .searching: return "searching"
        case .fixed: return "fixed"
        case .unsupported: return "unsupported"
        case .failed: return "failed"
        }
    }
}

/// Drives the module's built-in GNSS receiver through AT commands
/// (AT+QGPS / AT+QGPSLOC / AT+QGPSEND) and keeps a local position history.
@MainActor
final class GNSSController: ObservableObject {
    @Published private(set) var states: [CellularModuleID: GNSSModuleState] = [:]
    @Published private(set) var lastFixes: [CellularModuleID: GNSSFix] = [:]
    @Published private(set) var history: [GNSSFix] = []

    private weak var appState: AppState?
    private var timer: Timer?
    private var inFlight: Set<CellularModuleID> = []
    private var lastSatelliteQuery: [CellularModuleID: Date] = [:]
    private static let enabledKey = "GNSSEnabledModules.v1"
    private static let pollInterval: TimeInterval = 5
    private static let historyLimit = 5_000

    init(appState: AppState) {
        self.appState = appState
        history = Self.loadHistory()
    }

    var availableModules: [CellularModuleSummary] {
        appState?.cellularModules.filter { $0.modem.isConnected } ?? []
    }

    func isEnabled(_ moduleID: CellularModuleID) -> Bool {
        enabledModules.contains(moduleID.rawValue)
    }

    func state(for moduleID: CellularModuleID) -> GNSSModuleState {
        states[moduleID] ?? .off
    }

    func history(for moduleID: CellularModuleID) -> [GNSSFix] {
        history.filter { $0.moduleID == moduleID.rawValue }
    }

    /// Called once the app has started; resumes receivers that were left on.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func setEnabled(_ enabled: Bool, for moduleID: CellularModuleID,
                    completion: ((ModemActionResult) -> Void)? = nil) {
        var modules = enabledModules
        if enabled { modules.insert(moduleID.rawValue) } else { modules.remove(moduleID.rawValue) }
        UserDefaults.standard.set(Array(modules).sorted(), forKey: Self.enabledKey)
        if enabled {
            states[moduleID] = .starting
            powerOn(moduleID, completion: completion)
        } else {
            states[moduleID] = .off
            runAT("AT+QGPSEND", moduleID) { _ in completion?(.success(nil)) }
        }
    }

    func clearHistory(for moduleID: CellularModuleID) {
        history.removeAll { $0.moduleID == moduleID.rawValue }
        saveHistory()
    }

    // MARK: - Polling

    private var enabledModules: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
    }

    private func tick() {
        let connected = Set(availableModules.map(\.id))
        for moduleID in states.keys where !connected.contains(moduleID) {
            states[moduleID] = nil
        }
        for moduleID in connected where isEnabled(moduleID) {
            guard !inFlight.contains(moduleID), appState?.moduleHasCall(moduleID) != true else { continue }
            switch state(for: moduleID) {
            case .off, .failed:
                states[moduleID] = .starting
                powerOn(moduleID, completion: nil)
            case .starting, .searching, .fixed:
                poll(moduleID)
            case .unsupported:
                break
            }
        }
    }

    private func powerOn(_ moduleID: CellularModuleID, completion: ((ModemActionResult) -> Void)?) {
        runAT("AT+QGPS=1", moduleID) { [weak self] result in
            guard let self else { return }
            let output = result.output + (result.error ?? "")
            // 504: a GNSS session is already running.
            if result.isSuccess || output.contains("504") || output.localizedCaseInsensitiveContains("session is ongoing") {
                self.states[moduleID] = .searching(satellitesInView: nil)
                completion?(.success(nil))
                self.poll(moduleID)
            } else if output.contains("ERROR") && !output.contains("CME") {
                let message = L10n.tr("模组固件不支持 GNSS（AT+QGPS 返回 ERROR）。")
                self.states[moduleID] = .unsupported(message)
                completion?(.failure(message))
            } else {
                let message = result.error ?? L10n.tr("无法启动 GNSS。")
                self.states[moduleID] = .failed(message)
                completion?(.failure(message))
            }
        }
    }

    private func poll(_ moduleID: CellularModuleID) {
        runAT("AT+QGPSLOC=2", moduleID) { [weak self] result in
            guard let self, self.isEnabled(moduleID) else { return }
            if let fix = GNSSResponseParser.parseLocation(result.output, moduleID: moduleID.rawValue) {
                self.states[moduleID] = .fixed
                self.record(fix, moduleID: moduleID)
                return
            }
            let output = result.output + (result.error ?? "")
            if output.contains("505") || output.localizedCaseInsensitiveContains("not active") {
                // The receiver was switched off elsewhere (module restart).
                self.states[moduleID] = .starting
                self.powerOn(moduleID, completion: nil)
                return
            }
            self.querySatellitesIfDue(moduleID)
        }
    }

    private func querySatellitesIfDue(_ moduleID: CellularModuleID) {
        if case .searching = state(for: moduleID) {} else {
            states[moduleID] = .searching(satellitesInView: nil)
        }
        if let last = lastSatelliteQuery[moduleID], Date().timeIntervalSince(last) < 15 { return }
        lastSatelliteQuery[moduleID] = Date()
        runAT("AT+QGPSGNMEA=\"GSV\"", moduleID) { [weak self] result in
            guard let self, self.isEnabled(moduleID), case .searching = self.state(for: moduleID) else { return }
            self.states[moduleID] = .searching(
                satellitesInView: GNSSResponseParser.satellitesInView(result.output)
            )
        }
    }

    private func record(_ fix: GNSSFix, moduleID: CellularModuleID) {
        lastFixes[moduleID] = fix
        let previous = history.last { $0.moduleID == moduleID.rawValue }
        let moved = previous.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: fix.latitude, longitude: fix.longitude))
        } ?? .infinity
        let elapsed = previous.map { fix.timestamp.timeIntervalSince($0.timestamp) } ?? .infinity
        guard moved >= 10 || elapsed >= 60 else { return }
        history.append(fix)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        saveHistory()
    }

    private func runAT(_ command: String, _ moduleID: CellularModuleID,
                       completion: @escaping (ATConsoleExecutionResult) -> Void) {
        guard let appState else { return }
        inFlight.insert(moduleID)
        appState.runFeatureAT(command, via: moduleID) { [weak self] result in
            self?.inFlight.remove(moduleID)
            completion(result)
        }
    }

    // MARK: - Persistence

    private static var historyURL: URL {
        AppDataDirectory.userApplicationSupport().appendingPathComponent("gnss-history.json")
    }

    private static func loadHistory() -> [GNSSFix] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GNSSFix].self, from: data)) ?? []
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.historyURL, options: .atomic)
    }
}

enum GNSSResponseParser {
    /// Parses `+QGPSLOC: <UTC>,<lat>,<lon>,<hdop>,<alt>,<fix>,<cog>,<spkm>,<spkn>,<date>,<nsat>`
    /// as returned by AT+QGPSLOC=2 (decimal degrees).
    static func parseLocation(_ output: String, moduleID: String, now: Date = Date()) -> GNSSFix? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("+QGPSLOC:") }) else { return nil }
        let fields = line.dropFirst("+QGPSLOC:".count)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 11,
              let latitude = Double(fields[1]), let longitude = Double(fields[2]),
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        return GNSSFix(
            moduleID: moduleID,
            timestamp: utcDate(time: fields[0], date: fields[9]) ?? now,
            latitude: latitude,
            longitude: longitude,
            altitude: Double(fields[4]),
            hdop: Double(fields[3]),
            speedKmh: Double(fields[7]),
            course: courseDegrees(fields[6]),
            satellites: Int(fields[10]),
            fixDimension: Int(fields[5])
        )
    }

    /// Sums the "satellites in view" field of the first GSV sentence per
    /// constellation in an AT+QGPSGNMEA="GSV" response.
    static func satellitesInView(_ output: String) -> Int? {
        var counts: [String: Int] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            guard let start = raw.firstIndex(of: "$") else { continue }
            let sentence = raw[start...].split(separator: "*").first ?? ""
            let fields = sentence.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 3, fields[0].hasSuffix("GSV"), fields[2] == "1",
                  let count = Int(fields[3]) else { continue }
            counts[String(fields[0].dropFirst().prefix(2)), default: 0] = count
        }
        return counts.isEmpty ? nil : counts.values.reduce(0, +)
    }

    /// COG is reported as ddd.mm (degrees and minutes).
    private static func courseDegrees(_ value: String) -> Double? {
        guard let raw = Double(value) else { return nil }
        let degrees = floor(raw)
        return degrees + (raw - degrees) * 100 / 60
    }

    private static func utcDate(time: String, date: String) -> Date? {
        guard time.count >= 6, date.count == 6 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "ddMMyyHHmmss"
        return formatter.date(from: date + time.prefix(6))
    }
}

/// WGS-84 → GCJ-02, the datum Apple Maps uses inside mainland China. Outside
/// China the coordinate is returned unchanged. Standard published formula.
enum ChinaMapCoordinate {
    static func gcj02(fromWGS84 coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = coordinate.latitude, lon = coordinate.longitude
        guard isInsideChina(latitude: lat, longitude: lon) else { return coordinate }
        let a = 6378245.0, ee = 0.00669342162296594323
        var dLat = transformLatitude(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLongitude(x: lon - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
    }

    private static func isInsideChina(latitude: Double, longitude: Double) -> Bool {
        (73.66...135.05).contains(longitude) && (3.86...53.55).contains(latitude)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}
