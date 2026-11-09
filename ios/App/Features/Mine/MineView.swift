import SwiftUI

/// 我的 — MineActivity parity: 登录态、权益、设备管理、工单、通知、FAQ、
/// 设置、邀请码、注销、关于。次级页面按 1:1 端点实现（列表+详情精简版）。
struct MineView: View {

    @EnvironmentObject private var session: UserSession
    @EnvironmentObject private var vpn: VPNManager
    @State private var currentUser: CurrentUserData?
    @State private var entitlement: EntitlementData?
    @State private var devices: [DeviceInfo] = []

    var body: some View {
        NavigationStack {
            List {
                profileSection
                if session.isLoggedIn {
                    deviceSection
                    serviceSection
                    accountSection
                }
                infoSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("我的")
            .task { reload() }
        }
    }

    private var profileSection: some View {
        Section {
            if session.isLoggedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.username.isEmpty ? "用户" : session.username)
                        .font(.title3).bold()
                    Text(session.email).font(.caption).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        Tag(title: entitlement?.planName ?? "免费版", color: .yellow)
                        if let bound = currentUser?.boundInviteCode, !bound.isEmpty {
                            Tag(title: "邀请码 \(bound)", color: Theme.accent)
                        }
                    }
                }
                .padding(.vertical, 6)
            } else {
                NavigationLink {
                    LoginView()
                } label: {
                    Label("登录 / 注册", systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var deviceSection: some View {
        Section("设备管理 (上限内自动顶号)") {
            ForEach(devices, id: \.id) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.platform ?? "iOS")
                            .font(.body)
                        Text("\(device.lastIp ?? "-") · \(device.status ?? "-")")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("解绑") {
                        Task {
                            try? await APIService().deleteDevice(id: device.id)
                            reload()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private var serviceSection: some View {
        Section("服务") {
            NavigationLink { TicketListView() } label: { Label("工单", systemImage: "lifepreserver") }
            NavigationLink { NotificationsView() } label: { Label("通知", systemImage: "bell") }
            NavigationLink { FaqView() } label: { Label("常见问题", systemImage: "questionmark.circle") }
        }
    }

    private var accountSection: some View {
        Section("账号") {
            NavigationLink { InviteCodeView() } label: { Label("邀请码", systemImage: "gift") }
            NavigationLink { DeleteAccountView() } label: {
                Label("注销账号", systemImage: "trash")
                    .foregroundStyle(Theme.danger)
            }
            Button(role: .destructive) {
                UserSession.shared.logout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private var infoSection: some View {
        Section("关于") {
            LabeledRow(title: "版本", value: "1.0.1 (iOS)")
            LabeledRow(title: "引擎", value: "sing-box 1.13.0")
            LabeledRow(title: "设备ID", value: String(SharedStore.deviceID.prefix(8)) + "…")
        }
    }

    private func reload() {
        guard session.isLoggedIn else { return }
        Task {
            let api = APIService()
            currentUser = try? await api.getCurrentUser()
            entitlement = try? await api.getEntitlement()
            devices = (try? await api.getDeviceList())?.devices ?? []
        }
    }
}

// MARK: - 邀请码

struct InviteCodeView: View {
    @State private var inviteCode = ""
    @State private var bound: CurrentUserData?
    @State private var message: String?

    var body: some View {
        Form {
            Section("绑定好友邀请码") {
                TextField("邀请码", text: $inviteCode)
                    .textInputAutocapitalization(.never)
                Button("绑定") {
                    Task {
                        do {
                            try await APIService().submitInviteCode(
                                SubmitInviteCodeRequest(inviteCode: inviteCode)
                            )
                            message = "绑定成功"
                        } catch {
                            message = AppError.describe(error)
                        }
                    }
                }
            }
            Section("我的邀请信息") {
                if let share = bound?.shareText {
                    Text(share).font(.caption)
                }
                if let boundCode = bound?.boundInviteCode {
                    LabeledRow(title: "已绑定", value: boundCode)
                }
            }
            if let message {
                Text(message).foregroundStyle(Theme.accent)
            }
        }
        .task {
            bound = try? await APIService().getCurrentUser()
        }
        .navigationTitle("邀请码")
    }
}

// MARK: - 注销

struct DeleteAccountView: View {
    @EnvironmentObject private var session: UserSession
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("注销账号（输入邮箱验证码确认）") {
                TextField("验证码", text: $code)
                Button("发送验证码", role: .destructive) {
                    Task {
                        try? await APIService().sendVerificationCode(SendVerificationCodeRequest(
                            email: session.email, purpose: "delete_account",
                            captchaId: nil, captchaAnswer: nil
                        ))
                    }
                }
                Button("确认注销", role: .destructive) {
                    Task {
                        do {
                            try await APIService().deleteAccountByCode(
                                DeleteAccountByCodeRequest(code: code)
                            )
                            session.logout()
                            dismiss()
                        } catch {
                            message = AppError.describe(error)
                        }
                    }
                }
                .disabled(code.isEmpty)
            }
            if let message {
                Text(message).foregroundStyle(Theme.danger)
            }
        }
        .navigationTitle("注销账号")
    }
}

// MARK: - 工单

struct TicketListView: View {
    @State private var tickets: [TicketListItem] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger)
            }
            ForEach(tickets, id: \.ticketId) { ticket in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ticket.title ?? "").font(.body)
                    HStack {
                        Text(ticket.status ?? "").font(.caption)
                        Spacer()
                        Text(ticket.updatedAt ?? "").font(.caption2)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            if tickets.isEmpty && errorMessage == nil {
                Text("暂无工单").foregroundStyle(Theme.textSecondary)
            }
        }
        .task {
            do {
                tickets = try await APIService().getTickets()
            } catch {
                errorMessage = AppError.describe(error)
            }
        }
        .navigationTitle("工单")
    }
}

// MARK: - 通知

struct NotificationsView: View {
    @State private var notifications: [NotificationListItem] = []
    @State private var detail: NotificationDetailData?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger)
            }
            ForEach(notifications, id: \.notificationId) { item in
                Button {
                    Task {
                        detail = try? await APIService().getNotificationDetail(
                            id: item.notificationId ?? ""
                        )
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title ?? "").font(.body)
                        Text(item.publishedAt ?? "").font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(
            get: { detail.map(DetailBox.init) },
            set: { detail = $0?.detail }
        )) { box in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(box.detail.title ?? "").font(.title3).bold()
                        Text(box.detail.content ?? "")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            do {
                notifications = try await APIService().getNotifications()
            } catch {
                errorMessage = AppError.describe(error)
            }
        }
        .navigationTitle("通知")
    }

    private struct DetailBox: Identifiable {
        let detail: NotificationDetailData
        var id: String { detail.notificationId ?? UUID().uuidString }
    }
}

// MARK: - FAQ

struct FaqView: View {
    @State private var faqs: [FaqListItem] = []
    @State private var detail: FaqDetailData?

    var body: some View {
        List {
            ForEach(faqs, id: \.faqId) { item in
                Button {
                    Task {
                        detail = try? await APIService().getFaqDetail(id: item.faqId ?? "")
                    }
                } label: {
                    Text(item.question ?? "").foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(
            get: { detail.map(DetailBox.init) },
            set: { detail = $0?.detail }
        )) { box in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(box.detail.question ?? "").font(.title3).bold()
                        Text(box.detail.answer ?? "")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            faqs = (try? await APIService().getFaqs()) ?? []
        }
        .navigationTitle("常见问题")
    }

    private struct DetailBox: Identifiable {
        let detail: FaqDetailData
        var id: String { detail.faqId ?? UUID().uuidString }
    }
}

// MARK: - Widgets

struct Tag: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct LabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
        }
    }
}
