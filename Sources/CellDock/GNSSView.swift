import MapKit
import SwiftUI

struct GNSSView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: GNSSController
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
                Text(verbatim: L10n.tr("定位"))
                    .font(.appTitle)
                Spacer()
            }
            .padding(16)

            if controller.availableModules.isEmpty {
                ContentUnavailableView(
                    L10n.tr("没有可用模组"),
                    systemImage: "location.slash",
                    description: Text(verbatim: L10n.tr("连接蜂窝模组后即可使用模组内置的 GNSS 定位。"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(controller.availableModules) { module in
                        GNSSModuleRow(module: module, state: controller.state(for: module.id))
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
            GNSSDetailView(module: module, controller: controller)
        } else {
            ContentUnavailableView(
                L10n.tr("选择模组"),
                systemImage: "location",
                description: Text(verbatim: L10n.tr("选择一个模组以查看定位。"))
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

private struct GNSSModuleRow: View {
    let module: CellularModuleSummary
    let state: GNSSModuleState

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(GNSSStatusStyle.color(for: state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: module.localizedDisplayName).lineLimit(1)
                Text(verbatim: state.localizedTitle)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
    }
}

private enum GNSSStatusStyle {
    static func color(for state: GNSSModuleState) -> Color {
        switch state {
        case .fixed: return .green
        case .starting, .searching: return .orange
        case .failed, .unsupported: return .red
        case .off: return .secondary
        }
    }
}

private struct GNSSDetailView: View {
    @EnvironmentObject private var appState: AppState
    let module: CellularModuleSummary
    @ObservedObject var controller: GNSSController
    @State private var camera: MapCameraPosition = .automatic
    @State private var error: String?

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let fix = controller.lastFixes[module.id] {
                        map(fix)
                        details(fix)
                    } else if state.isActive {
                        searchingCard
                    }
                    historyCard
                    explanationCard
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .alert(L10n.tr("无法更改 GNSS"), isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button(L10n.tr("好"), role: .cancel) {}
        } message: {
            Text(verbatim: error ?? "")
        }
    }

    private var state: GNSSModuleState { controller.state(for: module.id) }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: module.localizedDisplayName).font(.appTitle)
                Text(verbatim: state.localizedTitle)
                    .font(.appCallout)
                    .foregroundStyle(GNSSStatusStyle.color(for: state))
            }
            Spacer()
            Toggle(L10n.tr("启用 GNSS"), isOn: Binding(
                get: { controller.isEnabled(module.id) },
                set: { enabled in
                    controller.setEnabled(enabled, for: module.id) { result in
                        if case .failure(let message) = result { error = message }
                    }
                }
            ))
            .toggleStyle(.adaptiveGlass)
            .disabled(appState.moduleHasCall(module.id))
        }
    }

    private func map(_ fix: GNSSFix) -> some View {
        let track = controller.history(for: module.id)
            .filter { Calendar.current.isDateInToday($0.timestamp) }
            .map(\.mapCoordinate)
        return Map(position: $camera) {
            if track.count > 1 {
                MapPolyline(coordinates: track).stroke(.blue.opacity(0.7), lineWidth: 3)
            }
            Marker(module.localizedDisplayName, systemImage: "antenna.radiowaves.left.and.right",
                   coordinate: fix.mapCoordinate)
                .tint(.green)
        }
        .mapControls {
            MapZoomStepper()
            MapCompass()
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onChange(of: fix) { _, newFix in
            if camera.positionedByUser { return }
            camera = .region(MKCoordinateRegion(center: newFix.mapCoordinate,
                                                latitudinalMeters: 800, longitudinalMeters: 800))
        }
    }

    private func details(_ fix: GNSSFix) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row(L10n.tr("纬度"), String(format: "%.6f", fix.latitude))
            row(L10n.tr("经度"), String(format: "%.6f", fix.longitude))
            if let altitude = fix.altitude { row(L10n.tr("海拔"), String(format: "%.1f m", altitude)) }
            if let hdop = fix.hdop { row(L10n.tr("水平精度因子（HDOP）"), String(format: "%.1f", hdop)) }
            if let speed = fix.speedKmh { row(L10n.tr("速度"), String(format: "%.1f km/h", speed)) }
            if let satellites = fix.satellites { row(L10n.tr("使用卫星"), String(satellites)) }
            row(L10n.tr("定位时间"), fix.timestamp.formatted(date: .abbreviated, time: .standard))
            HStack {
                Spacer()
                Button(L10n.tr("复制坐标")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(format: "%.6f,%.6f", fix.latitude, fix.longitude),
                                                   forType: .string)
                }
                .adaptiveGlassButton()
            }
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private var searchingCard: some View {
        Label(L10n.tr("正在等待定位。室内通常收不到卫星，把模组放到窗边或室外，首次定位可能需要几分钟。"),
              systemImage: "location.magnifyingglass")
            .font(.appCallout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlassSurface(cornerRadius: 14, padding: 12, treatment: .clear)
    }

    private var historyCard: some View {
        let points = controller.history(for: module.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("定位记录"), systemImage: "clock.arrow.circlepath")
                    .font(.appHeadline)
                Spacer()
                Button(L10n.tr("清除记录")) { controller.clearHistory(for: module.id) }
                    .adaptiveGlassButton()
                    .disabled(points.isEmpty)
            }
            if points.isEmpty {
                Text(verbatim: L10n.tr("还没有定位记录。"))
                    .font(.appCallout).foregroundStyle(.secondary)
            } else {
                ForEach(points.suffix(8).reversed()) { fix in
                    HStack {
                        Text(verbatim: fix.timestamp.formatted(date: .numeric, time: .shortened))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: String(format: "%.5f, %.5f", fix.latitude, fix.longitude))
                            .font(.appCallout.monospacedDigit())
                    }
                    .font(.appCallout)
                }
                Text(verbatim: L10n.tr("共 %lld 条，移动超过 10 米或间隔 1 分钟记录一次，只保存在这台 Mac。",
                                       Int64(points.count)))
                    .font(.appCaption).foregroundStyle(.secondary)
            }
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private var explanationCard: some View {
        Text(verbatim: L10n.tr("定位来自模组内置的 GNSS 接收机，CellDock 通过 AT 命令开关并每 5 秒读取一次位置。地图在中国大陆按 GCJ-02 显示，坐标值和记录仍是 WGS-84。"))
            .font(.appCaption)
            .foregroundStyle(.secondary)
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
