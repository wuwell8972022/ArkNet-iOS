import Foundation

/// Typed BFF API surface — 1:1 port of the 36 Retrofit endpoints catalogued
/// in the Android reverse-engineering report (§5).
struct APIService {

    private let client: BFFClient

    init(client: BFFClient = .shared ?? (try! BFFClient())) {
        self.client = client
    }

    // MARK: main — initialization / communication domains

    func getInitialization() async throws -> InitializationData {
        try await client.request("GET", "/api/v1/app/initialization", signed: false, authorize: false)
    }

    func getCommunicationDomains() async throws -> CommunicationDomainsData {
        try await client.request("GET", "/api/v1/communication-domains", signed: false, authorize: false)
    }

    // MARK: speed — nodes

    func getNodes(nodeType: String? = nil) async throws -> NodeListData {
        try await client.request(
            "GET", "/api/v1/nodes",
            query: nodeType.map { ["nodeType": $0] },
            authorize: true
        )
    }

    func connectNode(_ nodeId: String) async throws -> NodeConnectData {
        try await client.request("POST", "/api/v1/nodes/connect", body: NodeConnectRequest(nodeId: nodeId))
    }

    func checkNode(password: String) async throws -> Bool {
        let result: NodeCheckData = try await client.request(
            "POST", "/api/v1/nodes/check", body: NodeCheckRequest(password: password)
        )
        return result.valid
    }

    func disconnectNode() async throws -> NodeDisconnectData {
        try await client.request("POST", "/api/v1/nodes/disconnect")
    }

    func getRoutingRules() async throws -> RoutingRulesData {
        try await client.request("GET", "/api/v1/routing-rules")
    }

    // MARK: mine — auth

    func getCaptcha() async throws -> CaptchaData {
        try await client.request("GET", "/api/v1/auth/captcha", signed: false, authorize: false)
    }

    func login(_ request: LoginRequest) async throws -> LoginData {
        try await client.request("POST", "/api/v1/auth/login", body: request)
    }

    func register(_ request: RegisterRequest) async throws -> RegisterData {
        try await client.request("POST", "/api/v1/auth/register", body: request)
    }

    func sendVerificationCode(_ request: SendVerificationCodeRequest) async throws {
        let _: VerificationCodeData = try await client.request(
            "POST", "/api/v1/auth/verification-codes", body: request
        )
    }

    func verifyEmail(_ request: EmailVerifyRequest) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/auth/email/verify", body: request)
    }

    func resetPassword(_ request: ResetPasswordRequest) async throws {
        let _: ResetPasswordData = try await client.request("POST", "/api/v1/auth/password/reset", body: request)
    }

    func deleteAccountByCode(_ request: DeleteAccountByCodeRequest) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/auth/account/delete", body: request)
    }

    // MARK: mine — user profile / devices / entitlement

    func getCurrentUser() async throws -> CurrentUserData {
        try await client.request("GET", "/api/v1/users/me")
    }

    func getEntitlement() async throws -> EntitlementData {
        try await client.requestObject("GET", "/api/v1/users/me/entitlement")
            .map(EntitlementData.self)
    }

    func getBillingPolicy() async throws -> [String: Any] {
        try await client.requestObject("GET", "/api/v1/users/me/billing-policy")
    }

    func getDeviceList() async throws -> DeviceListData {
        try await client.request("GET", "/api/v1/users/me/devices")
    }

    func deleteDevice(id: Int64) async throws {
        let _: DeleteDeviceData = try await client.request(
            "DELETE", "/api/v1/users/me/devices/\(id)"
        )
    }

    func getProfileChangeQuota() async throws -> ProfileChangeQuotaData {
        try await client.request("GET", "/api/v1/users/me/profile-change-quota")
    }

    func changeEmail(_ request: ChangeEmailRequest) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/users/me/email", body: request)
    }

    func changePassword(_ request: ChangePasswordRequest) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/users/me/password", body: request)
    }

    func submitInviteCode(_ request: SubmitInviteCodeRequest) async throws {
        let _: InviteCodeBindData = try await client.request(
            "POST", "/api/v1/users/me/invite-code", body: request
        )
    }

    // MARK: mine — tickets

    func getTicketTypes() async throws -> [TicketTypeData] {
        let page: TicketTypesData = try await client.request("GET", "/api/v1/ticket-types")
        return page.types ?? []
    }

    func getTickets() async throws -> [TicketListItem] {
        let page: TicketListData = try await client.request("GET", "/api/v1/tickets")
        return page.tickets ?? []
    }

    func getTicketDetail(ticketId: String) async throws -> TicketDetailData {
        try await client.request("GET", "/api/v1/tickets/\(ticketId)")
    }

    func createTicket(_ request: CreateTicketRequest) async throws -> TicketDetailData {
        try await client.request("POST", "/api/v1/tickets", body: request)
    }

    func replyTicket(ticketId: String, content: String) async throws {
        let _: SuccessData = try await client.request(
            "POST", "/api/v1/tickets/\(ticketId)/replies", body: ReplyTicketRequest(content: content)
        )
    }

    func closeTicket(ticketId: String) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/tickets/\(ticketId)/close")
    }

    // MARK: mine — notifications / faq / legal

    func getNotifications() async throws -> [NotificationListItem] {
        let page: NotificationListData = try await client.request("GET", "/api/v1/notifications")
        return page.notifications ?? []
    }

    func getNotificationDetail(id: String) async throws -> NotificationDetailData {
        try await client.request("GET", "/api/v1/notifications/\(id)")
    }

    func getFaqs() async throws -> [FaqListItem] {
        let page: FaqListData = try await client.request("GET", "/api/v1/faqs")
        return page.faqs ?? []
    }

    func getFaqDetail(id: String) async throws -> FaqDetailData {
        try await client.request("GET", "/api/v1/faqs/\(id)")
    }

    func getLegalDocuments() async throws -> LegalDocumentsData {
        try await client.request("GET", "/api/v1/legal-documents")
    }

    // MARK: nav portal

    func getNavCarousels() async throws -> [NavCarouselData] {
        let data: NavCarouselsData = try await client.request("GET", "/api/v1/navigation/carousels")
        return data.carousels ?? []
    }

    func getNavCategories() async throws -> [NavCategoryData] {
        let data: NavCategoriesData = try await client.request("GET", "/api/v1/navigation/categories")
        return data.categories ?? []
    }

    func getNavItems() async throws -> [NavItemData] {
        let data: NavItemsData = try await client.request("GET", "/api/v1/navigation/items")
        return data.items ?? []
    }

    // MARK: marketing / rewards

    func getAnnouncements() async throws -> [AnnouncementData] {
        let page: AnnouncementListData = try await client.request("GET", "/api/v1/announcements")
        return page.announcements ?? []
    }

    func getAdsDelivery() async throws -> AdsDeliveryData {
        try await client.request("GET", "/api/v1/ads/delivery")
    }

    func claimAdReward(_ request: AdRewardClaimRequest) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/ads/reward-claims", body: request)
    }

    func reportAdEvent(_ body: [String: String]) async throws {
        let _: SuccessData = try await client.request("POST", "/api/v1/ads/events", body: AnyEncodable(body))
    }

    func getRewardSummary() async throws -> RewardSummaryData {
        try await client.request("GET", "/api/v1/users/me/rewards/summary")
    }

    func getRewardRecords() async throws -> RewardListData {
        try await client.request("GET", "/api/v1/users/me/rewards")
    }

    // MARK: update

    func getAppVersion() async throws -> AppVersionData {
        try await client.request("GET", "/api/v1/app/version", signed: false, authorize: false)
    }

    // MARK: loosely-typed wrappers

    /// Several list endpoints return `data:{list:[...],page:{...}}` shapes with
    /// names that may vary per deployment; decode defensively.
    private struct TicketTypesData: Decodable { let types: [TicketTypeData]? }
    private struct TicketListData: Decodable { let tickets: [TicketListItem]? }
    private struct NotificationListData: Decodable { let notifications: [NotificationListItem]? }
    private struct FaqListData: Decodable { let faqs: [FaqListItem]? }
    private struct NavCarouselsData: Decodable { let carousels: [NavCarouselData]? }
    private struct NavCategoriesData: Decodable { let categories: [NavCategoryData]? }
    private struct NavItemsData: Decodable { let items: [NavItemData]? }
    private struct AnnouncementListData: Decodable { let announcements: [AnnouncementData]? }
}

extension [String: Any] {
    /// Decode a loosely-typed dictionary into a Decodable payload.
    func map<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
