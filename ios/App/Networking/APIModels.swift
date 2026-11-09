import Foundation

// MARK: - Envelope

/// `ApiResponse<T>` from com.at.arknet.api — code 0 / "success" semantics
/// come from NodeApiExtKt.isOk (code==0 || code==200 handled server-side).
struct ApiResponse<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
    let success: Bool?

    var isOK: Bool { success ?? (code == 0 || code == 200) }
}

struct PageInfo: Decodable {
    let page: Int?
    let pageSize: Int?
    let total: Int?
}

// MARK: - Initialization

struct CommunicationDomainsData: Decodable {
    let domains: [String]?
    let endpoints: [String]?
    /// Accept either field naming; BFF may expose either.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String].self, forKey: .domains)
        endpoints = try c.decodeIfPresent([String].self, forKey: .endpoints)
    }
    private enum CodingKeys: String, CodingKey {
        case domains, endpoints
    }
    var allEndpoints: [String] { (domains ?? []) + (endpoints ?? []) }
}

struct InitializationData: Decodable {
    let channelWebsiteUrl: String?
    let announcements: [AnnouncementData]?
}

struct AnnouncementData: Decodable {
    let id: String?
    let title: String?
    let content: String?
    let publishedAt: String?
}

// MARK: - Nodes (speed module)

struct NodeListData: Decodable {
    let groups: [NodeGroupDto]?
    let nodes: [NodeDto]?
    let updatedAt: String?
}

struct NodeGroupDto: Decodable {
    let groupId: String?
    let name: String?
    let subtitle: String?
    let nodes: [NodeDto]?
}

struct NodeDto: Decodable {
    let nodeId: String
    let name: String?
    let ingress: String?
    let logo: String?
    let publicIp: String?
    let testPort: Int?
    let usageRatio: Int?
    let autoSelect: Bool?
    let weight: Int?
}

struct NodeConnectRequest: Encodable {
    let nodeId: String
}

/// Server-issued connection credentials (NodeConnectData).
struct NodeConnectData: Decodable {
    let ingress: String
    let listenPort: Int
    let password: String
    let proto: String
    let publicIp: String?
    let security: String
    let securityConfig: NodeSecurityConfig?
    let tlsServerName: String?
}

/// Reality triad (publicKey / serverName / shortId) — security == "reality".
struct NodeSecurityConfig: Decodable {
    let publicKey: String?
    let serverName: String?
    let shortId: String?
}

struct NodeCheckRequest: Encodable { let password: String }
struct NodeCheckData: Decodable { let valid: Bool }
struct NodeDisconnectData: Decodable { let dummy: String? }

struct RoutingRulesData: Decodable {
    let bypassAddresses: [String]?
    let outboundBlacklist: OutboundBlacklistData?
}

struct OutboundBlacklistData: Decodable {
    let domains: [String]?
    let ipCidr: [String]?
}

// MARK: - Auth (mine module)

struct LoginRequest: Encodable {
    let identifier: String
    let password: String
    let captchaId: String?
    let captchaAnswer: String?
    let email: String?
}

struct LoginData: Decodable {
    let token: String
    let userId: String?
    let email: String?
    let username: String?
    let emailVerified: Bool?
    let evictedDeviceId: Int64?
    let evictedDeviceClientId: String?
    let deviceCount: Int?
    let maxDevices: Int?
}

struct RegisterRequest: Encodable {
    let email: String
    let username: String
    let password: String
    /// 邮箱验证码 —— 可选：官方当前不下发，nil 时该字段不会出现在请求体里。
    let code: String?
    let captchaId: String?
    let captchaAnswer: String?
    let inviteCode: String?
}

struct RegisterData: Decodable { let userId: String? }

struct CaptchaData: Decodable {
    let captchaId: String
    let expiresIn: Int?
    let masterImage: String   // base64 (no data: prefix)
    let tileImage: String     // base64
    let tileX: Int
    let tileY: Int
}

struct SendVerificationCodeRequest: Encodable {
    let email: String
    let purpose: String       // register / reset_password / change_email ...
    let captchaId: String?
    let captchaAnswer: String?
}

struct VerificationCodeData: Decodable { let sent: Bool? }
struct EmailVerifyRequest: Encodable { let email: String; let code: String }
struct SuccessData: Decodable { let ok: Bool? }

struct ResetPasswordRequest: Encodable {
    let email: String
    let code: String
    let newPassword: String
}
struct ResetPasswordData: Decodable { let reset: Bool? }

struct ChangeEmailRequest: Encodable { let newEmail: String; let code: String }
struct ChangePasswordRequest: Encodable { let oldPassword: String; let newPassword: String }

struct DeleteAccountByCodeRequest: Encodable { let code: String }

struct UserProfile: Decodable {
    let userId: String?
    let username: String?
    let email: String?
    let emailVerified: Bool?
    let registeredAt: String?
}

struct CurrentUserData: Decodable {
    let user: UserProfile?
    let hasPendingReplyTicket: Bool?
    let channelWebsiteUrl: String?
    let boundInviteCode: String?
    let shareText: String?
    let showDisconnectProtection: Bool?
}

struct EntitlementData: Decodable {
    let entitlementType: String?     // "paid_subscription" / free tier
    let planName: String?
    let allowConnect: Bool
    let expiredAt: Int64?
    let periodicReset: Bool?
    let remainingDurationSeconds: Int64?
    let unlimitedTraffic: Bool?
    let trafficRemainingBytes: Int64?
}

struct BillingPolicyData: Decodable {
    let maxDevices: Int?
    let trafficPolicy: String?
    let raw: [String: String]?
}

struct DeviceInfo: Decodable {
    let id: Int64
    let deviceId: String?
    let platform: String?
    let model: String?
    let lastLoginAt: Int64?
    let userId: String?
    let status: String?
    let userAgent: String?
    let lastIp: String?
    let lastCountryCode: String?
    let lastRegion: String?
    let timezone: String?
    let oaid: String?
    let boundAt: Int64?
    let updatedAt: Int64?
}

struct DeviceListData: Decodable { let devices: [DeviceInfo]? }
struct DeleteDeviceData: Decodable { let removed: Bool? }

struct SubmitInviteCodeRequest: Encodable { let inviteCode: String }
struct InviteCodeBindData: Decodable { let bound: Bool? }

struct ProfileChangeQuotaData: Decodable {
    let quota: Int?
    let used: Int?
}

// MARK: - Tickets / Notifications / FAQ / Legal

struct TicketTypeData: Decodable { let id: String?; let name: String? }
struct TicketListItem: Decodable {
    let ticketId: String?
    let title: String?
    let status: String?
    let updatedAt: String?
}
struct TicketDetailData: Decodable {
    let ticketId: String?
    let title: String?
    let status: String?
    let replies: [TicketReplyItem]?
}
struct TicketReplyItem: Decodable {
    let replyId: String?
    let author: String?
    let content: String?
    let createdAt: String?
}
struct CreateTicketRequest: Encodable {
    let typeId: String
    let title: String
    let content: String
}
struct ReplyTicketRequest: Encodable { let content: String }

struct NotificationListItem: Decodable {
    let notificationId: String?
    let title: String?
    let publishedAt: String?
}
struct NotificationDetailData: Decodable {
    let notificationId: String?
    let title: String?
    let content: String?
    let publishedAt: String?
}

struct FaqListItem: Decodable {
    let faqId: String?
    let question: String?
}
struct FaqDetailData: Decodable {
    let faqId: String?
    let question: String?
    let answer: String?
}

struct LegalDocumentsData: Decodable {
    let privacyPolicyHtml: String?
    let userAgreementHtml: String?
    let cancellationAgreementHtml: String?
    let paymentAgreementHtml: String?
}

// MARK: - Navigation portal

struct NavCarouselData: Decodable {
    let title: String?
    let imageUrl: String?
    let jumpUrl: String?
}
struct NavCategoryData: Decodable { let id: String?; let name: String? }
struct NavItemData: Decodable {
    let id: String?
    let name: String?
    let url: String?
    let iconUrl: String?
    let recommended: Bool?
    let categoryId: String?
    let description: String?
}

// MARK: - Marketing / rewards / update

struct AdsDeliveryData: Decodable { let available: Bool?; let placementId: String? }
struct AdRewardClaimRequest: Encodable { let placementId: String; let eventId: String? }
struct RewardSummaryData: Decodable {
    let totalRewards: Int64?
    let trafficSummary: TrafficSummaryData?
}
struct TrafficSummaryData: Decodable {
    let uploadBytes: Int64?
    let downloadBytes: Int64?
}
struct RewardRecordData: Decodable {
    let rewardId: String?
    let amount: Int64?
    let reason: String?
    let createdAt: String?
}
struct RewardListData: Decodable { let records: [RewardRecordData]? }

struct AppVersionData: Decodable {
    let versionName: String?
    let versionCode: Int?
    let downloadUrl: String?
    let forceUpdate: Bool?
    let changelog: String?
}

// MARK: - Client log upload

struct ClientLogUploadRequest: Encodable { let fileName: String; let sizeBytes: Int64 }
struct ClientLogUploadData: Decodable {
    let uploadId: String?
    let uploadUrl: String?
    let headers: [String: String]?
}
struct CompleteUploadRequest: Encodable { let checksum: String? }
