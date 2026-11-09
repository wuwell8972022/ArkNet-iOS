import SwiftUI

/// 会员 — MemberActivity + MemberCheckoutActivity parity.
/// 1.0.1 Android 端支付为占位 UI（订单号本地生成、渠道静态），iOS 端按同一
/// 契约展示权益与套餐骨架；IAP 后端契约确定后在此接入 StoreKit 2。
struct MemberView: View {

    @EnvironmentObject private var session: UserSession
    @State private var entitlement: EntitlementData?
    @State private var summary: RewardSummaryData?
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    entitlementCard
                    inviteCard
                    rewardsCard
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Theme.danger)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("会员")
            .task { reload() }
            .refreshable { reload() }
        }
    }

    private var entitlementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "crown.fill").foregroundStyle(.yellow)
                Text(entitlement?.planName ?? (session.isLoggedIn ? "免费版" : "未登录"))
                    .font(.headline)
                Spacer()
                if entitlement?.unlimitedTraffic == true {
                    Text("不限流量").font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }
            if let expiredAt = entitlement?.expiredAt, expiredAt > 0 {
                Text("到期：\(format(expiredAt))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let remaining = entitlement?.trafficRemainingBytes, remaining >= 0 {
                Text("剩余流量：\(ByteFormat.format(remaining))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let duration = entitlement?.remainingDurationSeconds, duration > 0,
               entitlement?.periodicReset == true {
                Text("周期剩余：\(duration / 3600) 小时")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            // 支付占位（对齐 Android 1.0.1 MemberCheckoutActivity 本地 UI）
            Button {
                // TODO(IAP): StoreKit 2 + 服务端订单契约确定后接入
            } label: {
                Text("升级订阅（暂未开放）")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        }
        .padding(16)
        .background(Theme.cardBackground())
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("邀请好友", systemImage: "person.badge.plus")
                .font(.headline)
            if session.isLoggedIn {
                Text("在「我的 → 邀请码」绑定或分享邀请码获取奖励")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text("登录后可参与邀请活动")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground())
    }

    private var rewardsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("奖励概览", systemImage: "gift.fill")
                .font(.headline)
            if let summary {
                if let traffic = summary.trafficSummary {
                    Text("上传 \(ByteFormat.format(traffic.uploadBytes ?? 0)) · 下载 \(ByteFormat.format(traffic.downloadBytes ?? 0))")
                        .font(.caption.monospacedDigit())
                }
            } else {
                Text("—").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground())
    }

    private func reload() {
        guard session.isLoggedIn else { return }
        loading = true
        errorMessage = nil
        Task {
            do {
                let api = APIService()
                entitlement = try? await api.getEntitlement()
                summary = try? await api.getRewardSummary()
            }
            loading = false
        }
    }

    private func format(_ epoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
