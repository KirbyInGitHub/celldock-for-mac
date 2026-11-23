import Foundation

/// An LTE band set as Quectel writes it in AT+QCFG="band": a hex mask where
/// bit n is band n+1. EG25-G masks run past 64 bits (B66, B71), so the mask
/// is handled as text rather than as an integer.
struct LTEBandMask: Equatable {
    var bands: Set<Int>

    init(bands: Set<Int>) {
        self.bands = bands.filter { $0 >= 1 && $0 <= 256 }
    }

    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.count <= 64 else { return nil }
        var bands = Set<Int>()
        for (index, character) in digits.reversed().enumerated() {
            guard let nibble = character.hexDigitValue else { return nil }
            for bit in 0..<4 where nibble & (1 << bit) != 0 {
                bands.insert(index * 4 + bit + 1)
            }
        }
        self.bands = bands
    }

    var hex: String {
        guard let highest = bands.max() else { return "0x0" }
        var nibbles = [Int](repeating: 0, count: (highest - 1) / 4 + 1)
        for band in bands {
            nibbles[(band - 1) / 4] |= 1 << ((band - 1) % 4)
        }
        return "0x" + nibbles.reversed().map { String($0, radix: 16) }.joined()
    }
}

/// AT+QCFG="band": `+QCFG: "band",<gw>,<lte>,<tds>`.
struct ModuleBandConfiguration: Equatable {
    var gwMask: String
    var lte: LTEBandMask
    var tdsMask: String

    static func parse(_ output: String) -> ModuleBandConfiguration? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("+QCFG:") && $0.contains("\"band\"") }) else { return nil }
        let fields = line.dropFirst("+QCFG:".count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        guard fields.count >= 4, let lte = LTEBandMask(hex: fields[2]) else { return nil }
        return ModuleBandConfiguration(gwMask: fields[1], lte: lte, tdsMask: fields[3])
    }

    /// Keeps the GSM/UMTS and TD-SCDMA masks as read, so only LTE changes.
    /// The module reports masks with a 0x prefix but rejects them with one
    /// when written (EG25-G answers ERROR), so they are written as bare hex.
    func writeCommand(lte bands: Set<Int>) -> String {
        let fields = [gwMask, LTEBandMask(bands: bands).hex, tdsMask].map(Self.bareHex)
        return "AT+QCFG=\"band\",\(fields.joined(separator: ",")),1"
    }

    private static func bareHex(_ value: String) -> String {
        let lower = value.lowercased()
        return lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
    }
}

/// AT+QCFG="nwscanmode" values shown in CellDock. China's LTE carriers have no
/// usable 2G/3G fallback for these modules, so only automatic and LTE-only are
/// offered.
enum ModuleScanMode: Int, CaseIterable, Identifiable {
    case automatic = 0
    case lteOnly = 3

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .automatic: return L10n.tr("自动")
        case .lteOnly: return L10n.tr("仅 LTE")
        }
    }

    static func parse(_ output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("\"nwscanmode\"") }),
              let value = line.split(separator: ",").dropFirst().first else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }
}

/// AT+QTEMP. EG25-G answers `+QTEMP: <pmic>,<xo>,<pa>`; newer firmware lists
/// named sensors as `+QTEMP:"name","value"` lines. Readings of 0 or less and
/// above 150 are sensor placeholders.
enum ModuleTemperature {
    struct Reading: Equatable {
        let name: String
        let celsius: Int
    }

    static func parse(_ output: String) -> [Reading] {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("+QTEMP:") }
        var readings: [Reading] = []
        for line in lines {
            let fields = line.dropFirst("+QTEMP:".count)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            if fields.count == 2, Int(fields[0]) == nil, let value = Int(fields[1]) {
                readings.append(Reading(name: fields[0], celsius: value))
            } else {
                let names = ["PMIC", "XO", "PA"]
                for (index, field) in fields.enumerated() {
                    guard let value = Int(field) else { continue }
                    readings.append(Reading(
                        name: index < names.count ? names[index] : "T\(index + 1)",
                        celsius: value
                    ))
                }
            }
        }
        return readings.filter { $0.celsius > 0 && $0.celsius <= 150 }
    }
}

/// One serving-cell measurement kept for the signal history chart.
struct SignalSample: Codable, Equatable, Identifiable {
    var id: String { "\(module)|\(timestamp.timeIntervalSince1970)" }
    let module: String
    let timestamp: Date
    let rsrp: Int
    let sinr: Int?
    let rsrq: Int?
    let band: String?
    let cellID: String?
}
