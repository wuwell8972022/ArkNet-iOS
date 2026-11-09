import SwiftUI

/// Home — connect card + traffic + mode selector + node entry
/// (MainHomeActivity parity).
struct HomeView: View {

    @EnvironmentObject private var vpn: VPNManager
    @EnvironmentObject private var engine: TunnelCommandClient
    @State private var showNodeSelect = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectCard(
                        state: vpn.state,
                        nodeName: vpn.currentNode.map { "\($0.serverHost):\($0.serverPort)" },
                        delayMs: engine.nodeDelayMs,
                        onConnectTap: handleConnectTap,
                        onUrlTest: {
                            try? engine.urlTest()
                        }
                    )

                    ModePicker(mode: Binding(
                        get: { vpn.mode },
                        set: { newMode in
                            Task { await vpn.switchMode(newMode) }
                        }
                    ))

                    trafficCard

                    Button {
                        showNodeSelect = true
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                            Text("选择节点")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(16)
                        .background(Theme.cardBackground())
                        .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    if let error = vpn.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.cardBackground())
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("安心加速器")
            .navigationDestination(isPresented: $showNodeSelect) {
                NodeSelectView()
            }
        }
    }

    private var trafficCard: some View {
        HStack(spacing: 0) {
            trafficColumn(title: "上传", value: ByteFormat.format(engine.uplinkBytes),
                          total: ByteFormat.format(engine.uplinkTotal))
            Divider().frame(height: 44).background(Theme.surfaceAlt)
            trafficColumn(title: "下载", value: ByteFormat.format(engine.downlinkBytes),
                          total: ByteFormat.format(engine.downlinkTotal))
        }
        .padding(16)
        .background(Theme.cardBackground())
    }

    private func trafficColumn(title: String, value: String, total: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text("累计 \(total)").font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func handleConnectTap() {
        Task {
            if vpn.isSelected {
                await vpn.disconnect()
            } else {
                // Auto-select: first recommended node (autoSelect flag), else first.
                let nodes = (try? await APIService().getNodes())?.groups?.first?.nodes
                    ?? (try? await APIService().getNodes())?.nodes ?? []
                guard let target = nodes.first(where: { $0.autoSelect == true }) ?? nodes.first else {
                    vpn.lastError = "暂无可用节点"
                    return
                }
                await vpn.connect(to: target)
            }
        }
    }
}

/// Big circular connect button + status ring (首页连接卡).
struct ConnectCard: View {

    let state: VPNManager.ConnectionState
    let nodeName: String?
    let delayMs: Int32
    let onConnectTap: () -> Void
    let onUrlTest: () -> Void

    private var statusText: String {
        switch state {
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已加速"
        case .disconnecting: return "断开中…"
        case .error: return "连接失败"
        }
    }

    private var ringColor: Color {
        switch state {
        case .connected: return Theme.accent
        case .connecting, .disconnecting: return Color.orange
        case .error: return Theme.danger
        case .disconnected: return Theme.surfaceAlt
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Button(action: onConnectTap) {
                ZStack {
                    Circle()
                        .stroke(ringColor.opacity(0.35), lineWidth: 10)
                        .frame(width: 168, height: 168)
                    if state == .connecting || state == .disconnecting {
                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(ringColor, lineWidth: 10)
                            .frame(width: 168, height: 168)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: state)
                    }
                    Image(systemName: state == .connected ? "pause.fill" : "bolt.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(state == .disconnected ? Theme.textSecondary : ringColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(state == .connecting || state == .disconnecting)

            Text(statusText)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            if let nodeName {
                Text(nodeName).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if delayMs > 0 {
                HStack(spacing: 6) {
                    Circle().fill(delayMs < 120 ? .green : (delayMs < 300 ? .orange : Theme.danger))
                        .frame(width: 6, height: 6)
                    Text("\(delayMs) ms")
                        .font(.caption.monospacedDigit())
                }
                .onTapGesture(perform: onUrlTest)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.cardBackground())
    }
}

/// 智能 / 全局 / 指定 — speed_mode_* parity (specified == smart on iOS).
struct ModePicker: View {

    @Binding var mode: TunnelConfigBuilder.Mode

    private let options: [(TunnelConfigBuilder.Mode, String, String)] = [
        (.smart, "智能", "square.split.2x2"),
        (.global, "全局", "globe"),
        (.specified, "指定", "slider.horizontal.3")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { option, title, icon in
                Button {
                    mode = option
                } label: {
                    HStack {
                        Image(systemName: icon)
                        Text(title)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(mode == option ? Theme.accentSoft : Color.clear)
                    .foregroundStyle(mode == option ? Theme.accent : Theme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Theme.cardBackground())
    }
}
