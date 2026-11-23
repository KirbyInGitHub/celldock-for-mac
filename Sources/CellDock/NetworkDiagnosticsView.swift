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

private struct NetworkDiagnosticsDetailView: View {
    let module: CellularModuleSummary
    @ObservedObject var controller: NetworkDiagnosticsController

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
                    trafficCard
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            if result == nil { controller.runDiagnostics(for: module) }
        }
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
            Text(verbatim: L10n.tr("按模组网卡的收发字节统计，CellDock 运行时才记录，只保存在这台 Mac；运营商账单以运营商为准。"))
                .font(.appCaption).foregroundStyle(.secondary)
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
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
