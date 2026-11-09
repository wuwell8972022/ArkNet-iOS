import SwiftUI

/// Node selection — NodeSelectActivity parity:
/// GET /api/v1/nodes → groups (NodeGroupDto) → per-node latency via urlTest.
struct NodeSelectView: View {

    @EnvironmentObject private var vpn: VPNManager
    @EnvironmentObject private var engine: TunnelCommandClient
    @State private var groups: [NodeGroupDto] = []
    @State private var looseNodes: [NodeDto] = []
    @State private var loading = false
    @State private var testingLatency = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    testLatency()
                } label: {
                    HStack {
                        if testingLatency {
                            ProgressView().controlSize(.small)
                        }
                        Text(testingLatency ? "测速中…" : "测速")
                        Spacer()
                        Image(systemName: "timer")
                    }
                }
                .disabled(testingLatency)
            } footer: {
                Text("延迟由引擎 urltest 测量（gstatic 204）")
            }

            if !looseNodes.isEmpty {
                Section("节点") {
                    ForEach(looseNodes, id: \.nodeId) { node in
                        nodeRow(node)
                    }
                }
            }
            ForEach(groups, id: \.groupId) { group in
                Section(group.name ?? "节点组") {
                    ForEach(group.nodes ?? [], id: \.nodeId) { node in
                        nodeRow(node)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("选择节点")
        .task { reload() }
    }

    private func nodeRow(_ node: NodeDto) -> some View {
        Button {
            Task {
                loading = true
                await vpn.connect(to: node)
                loading = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name ?? node.nodeId)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        if let publicIp = node.publicIp, !publicIp.isEmpty {
                            Text(publicIp).font(.caption2.monospaced())
                        }
                        if let ratio = node.usageRatio, ratio > 0 {
                            Text("负载 \(ratio)%").font(.caption2)
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if vpn.currentNode?.nodeId == node.nodeId {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
                if loading {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        loading = true
        Task {
            do {
                let data = try await APIService().getNodes()
                groups = data.groups ?? []
                looseNodes = data.nodes ?? []
                errorMessage = nil
            } catch {
                errorMessage = AppError.describe(error)
            }
            loading = false
        }
    }

    private func testLatency() {
        testingLatency = true
        engine.resetDelay()
        do {
            try engine.urlTest()
        } catch {
            errorMessage = AppError.describe(error)
        }
        // The group stream callback updates engine.nodeDelayMs asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            testingLatency = false
        }
    }
}
