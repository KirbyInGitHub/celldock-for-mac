import Charts
import SwiftUI

struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: NetworkDiagnosticsController
    @Binding var sidebarWidth: CGFloat
    @Binding var networkToolsTab: NetworkToolsTab
    @State private var selectedModuleID: CellularModuleID?

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            sidebar
                .communicationSidebarColumnStyle()
                .communicationModuleFloatingSidebar()
        } detail: {
            detail
                .communicationDetailColumnStyle()
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: controller.availableModules.map(\.id)) { _, _ in reconcileSelection() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            NetworkToolsTabBar(selection: $networkToolsTab)
            HStack {
                Text(verbatim: L10n.tr("诊断"))
                    .font(.appTitle)
                Spacer()
            }
            .padding(16)

            if controller.availableModules.isEmpty {
                ContentUnavailableView(
                    L10n.tr("没有可用模组"),
                    systemImage: "stethoscope",
                    description: Text(verbatim: L10n.tr("连接蜂窝模组后即可诊断网络和查看流量。"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(controller.availableModules) { module in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: module.localizedDisplayName).lineLimit(1)
                            Text(verbatim: [module.carrierName, module.network.bsdName]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.appCaption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .communicationSelectionHighlight(selectedModuleID == module.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedModuleID = module.id }
                        .accessibilityAddTraits(selectedModuleID == module.id ? .isSelected : [])
                    }
                }
                .listStyle(.sidebar)
                .communicationEmphasizedSelection()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let module = controller.availableModules.first(where: { $0.id == selectedModuleID }) {
            NetworkDiagnosticsDetailView(module: module, controller: controller)
        } else {
            ContentUnavailableView(
                L10n.tr("选择模组"),
                systemImage: "stethoscope",
                description: Text(verbatim: L10n.tr("选择一个模组以诊断网络。"))
            )
        }
    }

    private func reconcileSelection() {
        selectedModuleID = CellularModuleSelectionPolicy.reconciledManagementSelection(
            current: selectedModuleID,
            available: controller.availableModules.map(\.id)
        )
    }
}

private enum SignalRange: String, CaseIterable, Identifiable {
    case sixHours, day, week

    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        }
    }
    var title: String {
        switch self {
        case .sixHours: return L10n.tr("6 小时")
        case .day: return L10n.tr("24 小时")
        case .week: return L10n.tr("7 天")
        }
    }
}

private struct NetworkDiagnosticsDetailView: View {
    let module: CellularModuleSummary
    @ObservedObject var controller: NetworkDiagnosticsController
    @State private var signalRange = SignalRange.day
    @State private var selectedBands: Set<Int>?
    @State private var dataCapText = ""

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(verbatim: module.localizedDisplayName).font(.appTitle)
                        Spacer()
                        Button {
                            controller.runDiagnostics(for: module)
                        } label: {
                            if result?.isRunning == true {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(L10n.tr("运行检测"), systemImage: "stethoscope")
                            }
                        }
                        .adaptiveGlassButton()
                        .disabled(result?.isRunning == true)
                    }
                    macCard
                    if let result, result.checkedAt != nil {
                        checksCard(result)
                        radioCard(result)
                    }
                    signalCard
                    bandCard
                    trafficCard
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            if result == nil { controller.runDiagnostics(for: module) }
        }
        .task(id: module.id) {
            selectedBands = nil
            dataCapText = controller.dataCapGB(for: module)
                .map { $0.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) } ?? ""
            controller.loadRadio(for: module)
        }
    }

    private var radioState: ModuleRadioState? { controller.radio[module.id] }

    // MARK: Signal history

    private var signalCard: some View {
        let samples = controller.signalHistory(for: module, since: Date().addingTimeInterval(-signalRange.seconds))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("信号记录"), systemImage: "waveform.path.ecg").font(.appHeadline)
                Spacer()
                Picker("", selection: $signalRange) {
                    ForEach(SignalRange.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if samples.isEmpty {
                Text(verbatim: L10n.tr("还没有记录。CellDock 每分钟读取一次服务小区，几分钟后这里会出现曲线。"))
                    .font(.appCallout).foregroundStyle(.secondary)
            } else {
                signalSummary(samples)
                Chart {
                    RuleMark(y: .value("RSRP", -100))
                        .foregroundStyle(.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(samples) { sample in
                        LineMark(x: .value(L10n.tr("时间"), sample.timestamp),
                                 y: .value("RSRP", sample.rsrp))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value(L10n.tr("时间"), sample.timestamp),
                                  y: .value("RSRP", sample.rsrp))
                            .symbolSize(samples.count > 60 ? 0 : 16)
                    }
                }
                .chartYAxisLabel("RSRP dBm")
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 150)
                let sinrSamples = samples.filter { $0.sinr != nil }
                if !sinrSamples.isEmpty {
                    Chart(sinrSamples) { sample in
                        LineMark(x: .value(L10n.tr("时间"), sample.timestamp),
                                 y: .value("SINR", sample.sinr ?? 0))
                            .foregroundStyle(.teal)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value(L10n.tr("时间"), sample.timestamp),
                                  y: .value("SINR", sample.sinr ?? 0))
                            .foregroundStyle(.teal)
                            .symbolSize(sinrSamples.count > 60 ? 0 : 16)
                    }
                    .chartYAxisLabel("SINR dB")
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 90)
                }
            }
            HStack {
                Text(verbatim: L10n.tr("虚线是 -100 dBm，低于它信号偏弱。记录保留 7 天，只存在这台 Mac。"))
                    .font(.appCaption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("清除记录")) { controller.clearSignalHistory(for: module) }
                    .adaptiveGlassButton()
                    .disabled(samples.isEmpty)
            }
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func signalSummary(_ samples: [SignalSample]) -> some View {
        let rsrps = samples.map(\.rsrp)
        let average = rsrps.reduce(0, +) / max(1, rsrps.count)
        let sinrs = samples.compactMap(\.sinr)
        let cellChanges = zip(samples, samples.dropFirst()).filter { $0.cellID != $1.cellID }.count
        let bands = Array(Set(samples.compactMap(\.band))).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        return HStack(spacing: 24) {
            stat(L10n.tr("当前"), "\(rsrps.last ?? 0) dBm")
            stat(L10n.tr("平均"), "\(average) dBm")
            stat(L10n.tr("最低"), "\((rsrps.min() ?? 0)) dBm")
            if !sinrs.isEmpty {
                stat(L10n.tr("平均 SINR"), "\(sinrs.reduce(0, +) / sinrs.count) dB")
            }
            stat(L10n.tr("小区切换"), "\(cellChanges)")
            if !bands.isEmpty {
                stat(L10n.tr("频段"), bands.map { "B\($0)" }.joined(separator: " "))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.appCaption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.appBodyStrong.monospacedDigit())
        }
    }

    // MARK: Bands, scan mode, temperature

    private var bandCard: some View {
        let state = radioState
        let current = state?.bands?.lte.bands ?? []
        let available = (controller.originalBands(for: module) ?? current).union(current).sorted()
        let selection = selectedBands ?? current
        let servingBand = (result?.servingCell?.band
            ?? controller.signalHistory(for: module, since: Date().addingTimeInterval(-300)).last?.band)
            .flatMap(Int.init)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("频段与制式"), systemImage: "dial.medium").font(.appHeadline)
                Spacer()
                if state?.isBusy == true { ProgressView().controlSize(.small) }
                Button {
                    controller.loadRadio(for: module)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .adaptiveGlassButton()
                .help(L10n.tr("重新读取"))
            }
            if let scanMode = state?.scanMode {
                HStack {
                    Text(verbatim: L10n.tr("网络制式")).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { ModuleScanMode(rawValue: scanMode) },
                        set: { if let mode = $0 { controller.setScanMode(mode, for: module) } }
                    )) {
                        if ModuleScanMode(rawValue: scanMode) == nil {
                            Text(verbatim: L10n.tr("其他（%lld）", Int64(scanMode))).tag(ModuleScanMode?.none)
                        }
                        ForEach(ModuleScanMode.allCases) { Text(verbatim: $0.localizedTitle).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(state?.isBusy == true)
                }
                .font(.appCallout)
            }
            if !available.isEmpty {
                Text(verbatim: L10n.tr("允许的 LTE 频段"))
                    .font(.appCallout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(available, id: \.self) { band in
                        bandChip(band, isOn: selection.contains(band), isServing: band == servingBand) {
                            var updated = selection
                            if updated.contains(band) { updated.remove(band) } else { updated.insert(band) }
                            selectedBands = updated
                        }
                    }
                }
                HStack {
                    Button(L10n.tr("应用")) {
                        controller.setLTEBands(selection, for: module)
                        selectedBands = nil
                    }
                    .adaptiveGlassButton()
                    .disabled(selection.isEmpty || selection == current || state?.isBusy == true)
                    if let original = controller.originalBands(for: module), original != current {
                        Button(L10n.tr("恢复全部频段")) {
                            controller.setLTEBands(original, for: module)
                            selectedBands = nil
                        }
                        .adaptiveGlassButton()
                        .disabled(state?.isBusy == true)
                    }
                    Spacer()
                }
                Text(verbatim: L10n.tr("锁定到信号最好的频段可以减少模组在弱频段之间来回切换。中国电信 4G 常用 B1、B3、B5。选错频段会断网，可随时恢复全部频段。"))
                    .font(.appCaption).foregroundStyle(.secondary)
            } else if state != nil {
                Text(verbatim: L10n.tr("模组没有返回频段配置。"))
                    .font(.appCallout).foregroundStyle(.secondary)
            }
            if let temperatures = state?.temperatures, !temperatures.isEmpty {
                row(L10n.tr("模组温度"), temperatures.map { "\($0.name) \($0.celsius)°C" }.joined(separator: " · "))
            }
            if let message = state?.message {
                Text(verbatim: message).font(.appCaption).foregroundStyle(.green)
            }
            if let error = state?.error {
                Text(verbatim: error).font(.appCaption).foregroundStyle(.red)
            }
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func bandChip(_ band: Int, isOn: Bool, isServing: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isServing { Image(systemName: "antenna.radiowaves.left.and.right").font(.appCaption) }
                Text(verbatim: "B\(band)").font(.appCallout.weight(.semibold).monospacedDigit())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(isOn ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(isServing ? L10n.tr("当前服务频段") : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var result: ModuleDiagnostics? { controller.diagnostics[module.id] }

    private var macCard: some View {
        let network = module.network
        return VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("Mac 网络"), systemImage: "desktopcomputer").font(.appHeadline)
            row(L10n.tr("模组网卡"), network.bsdName ?? L10n.tr("未发现"))
            row("IPv4", network.ipv4Address ?? "—")
            row(L10n.tr("网关"), network.ipv4Router ?? "—")
            row("IPv6", network.ipv6Address ?? "—")
            row("DNS", network.dnsServers.isEmpty ? "—" : network.dnsServers.joined(separator: ", "))
            row(L10n.tr("系统默认出口"), result?.defaultRouteInterface.map {
                $0 == network.bsdName ? L10n.tr("%@（模组）", $0) : $0
            } ?? "—")
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func checksCard(_ result: ModuleDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("连通性"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.appHeadline)
                Spacer()
                if let date = result.checkedAt {
                    Text(verbatim: date.formatted(date: .omitted, time: .standard))
                        .font(.appCaption).foregroundStyle(.secondary)
                }
            }
            ForEach(result.checks) { check in
                HStack {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.ok ? .green : .red)
                    Text(verbatim: check.name)
                    Spacer()
                    Text(verbatim: check.detail).foregroundStyle(.secondary)
                }
                .font(.appCallout)
            }
            Text(verbatim: L10n.tr("检测都绑定在模组网卡上，即使 Wi-Fi 是默认出口也测的是蜂窝链路。"))
                .font(.appCaption).foregroundStyle(.secondary)
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func radioCard(_ result: ModuleDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("无线与数据连接"), systemImage: "antenna.radiowaves.left.and.right")
                .font(.appHeadline)
            if let cell = result.servingCell {
                if let technology = cell.technology {
                    row(L10n.tr("制式"), [technology, cell.duplex].compactMap { $0 }.joined(separator: " "))
                }
                if let band = cell.band { row(L10n.tr("频段"), "B\(band)") }
                if let earfcn = cell.earfcn { row("EARFCN", earfcn) }
                if let mcc = cell.mcc, let mnc = cell.mnc { row("MCC / MNC", "\(mcc) / \(mnc)") }
                if let cellID = cell.cellID { row(L10n.tr("小区 ID / PCI"), "\(cellID) / \(cell.physicalCellID ?? "—")") }
                if let tac = cell.tac { row("TAC", tac) }
                if let rsrp = cell.rsrp { row("RSRP", "\(rsrp) dBm · \(quality(rsrp: rsrp))") }
                if let rsrq = cell.rsrq { row("RSRQ", "\(rsrq) dB") }
                if let sinr = cell.sinr { row("SINR", "\(sinr) dB") }
                if cell.technology != "LTE" {
                    Text(verbatim: cell.raw).font(.appMono).textSelection(.enabled)
                }
            } else {
                Text(verbatim: L10n.tr("模组没有返回服务小区信息。"))
                    .font(.appCallout).foregroundStyle(.secondary)
            }
            if let contexts = result.pdpContexts, !contexts.isEmpty {
                Text(verbatim: contexts)
                    .font(.appMono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private var trafficCard: some View {
        let days = controller.days(for: module, last: 14)
        let month = controller.monthTotal(for: module)
        let today = days.last
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("蜂窝流量"), systemImage: "chart.bar").font(.appHeadline)
                Spacer()
                Button(L10n.tr("清除记录")) { controller.clearTraffic(for: module) }
                    .adaptiveGlassButton()
            }
            HStack(spacing: 24) {
                total(L10n.tr("今天"), (today?.received ?? 0) + (today?.sent ?? 0))
                total(L10n.tr("本月"), month.received + month.sent)
                total(L10n.tr("本月下载"), month.received)
                total(L10n.tr("本月上传"), month.sent)
            }
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value(L10n.tr("日期"), String(day.day.suffix(5))),
                            y: .value(L10n.tr("流量"), Double(day.received) / 1_048_576))
                        .foregroundStyle(by: .value(L10n.tr("方向"), L10n.tr("下载")))
                    BarMark(x: .value(L10n.tr("日期"), String(day.day.suffix(5))),
                            y: .value(L10n.tr("流量"), Double(day.sent) / 1_048_576))
                        .foregroundStyle(by: .value(L10n.tr("方向"), L10n.tr("上传")))
                }
            }
            .chartYAxisLabel("MB")
            .frame(height: 180)
            dataCapRow(used: month.received + month.sent)
            Text(verbatim: L10n.tr("按模组网卡的收发字节统计，CellDock 运行时才记录，只保存在这台 Mac；运营商账单以运营商为准。"))
                .font(.appCaption).foregroundStyle(.secondary)
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func dataCapRow(used: UInt64) -> some View {
        let cap = controller.dataCapGB(for: module)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: L10n.tr("每月套餐")).foregroundStyle(.secondary)
                Spacer()
                TextField(L10n.tr("不限"), text: $dataCapText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit(saveDataCap)
                Text(verbatim: "GB").foregroundStyle(.secondary)
                Button(L10n.tr("保存"), action: saveDataCap).adaptiveGlassButton()
            }
            .font(.appCallout)
            if let cap {
                let limit = cap * 1_073_741_824
                ProgressView(value: min(Double(used), limit), total: limit)
                    .tint(Double(used) >= limit ? .red : Double(used) >= limit * 0.8 ? .orange : .accentColor)
                Text(verbatim: L10n.tr("本月已用 %lld%%，到 80%% 和用完时各提醒一次。",
                                       Int64((Double(used) / limit * 100).rounded())))
                    .font(.appCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveDataCap() {
        let trimmed = dataCapText.trimmingCharacters(in: .whitespaces)
        let value = Double(trimmed.replacingOccurrences(of: ",", with: "."))
        controller.setDataCapGB(value, for: module)
        if value == nil || value ?? 0 <= 0 { dataCapText = "" }
    }

    private func total(_ title: String, _ bytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.appCaption).foregroundStyle(.secondary)
            Text(verbatim: NetworkSpeedFormatter.byteCount(bytes)).font(.appBodyStrong.monospacedDigit())
        }
    }

    private func quality(rsrp: Int) -> String {
        switch rsrp {
        case (-80)...: return L10n.tr("很好")
        case (-90)...: return L10n.tr("好")
        case (-100)...: return L10n.tr("一般")
        default: return L10n.tr("弱")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.appCallout)
    }
}
