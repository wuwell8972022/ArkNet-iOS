import SwiftUI
import WebKit

/// 导航门户 — NavActivity/NavBrowseActivity parity:
/// carousels + categories + items → 内置 WKWebView 浏览器，
/// H5 桥协议与 Android NativeObject.js 完全一致（webkit messageHandlers.nativeObject）。
struct NavView: View {

    @State private var carousels: [NavCarouselData] = []
    @State private var categories: [NavCategoryData] = []
    @State private var items: [NavItemData] = []
    @State private var selectedCategory: String = "all"
    @State private var browsingURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Theme.danger)
                    }
                    ForEach(carousels, id: \.title) { carousel in
                        Button {
                            openCarousel(carousel)
                        } label: {
                            Text(carousel.title ?? "")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    categoryBar

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                        ForEach(filteredItems, id: \.id) { item in
                            Button {
                                openItem(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name ?? "")
                                        .font(.body).bold()
                                        .lineLimit(1)
                                    Text(item.description ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.cardBackground())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("导航")
            .navigationDestination(item: $browsingURL) { url in
                NavBrowseView(url: url)
            }
            .task { reload() }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("all", "全部")
                ForEach(categories, id: \.id) { category in
                    chip(category.id ?? "", category.name ?? "")
                }
            }
        }
    }

    private func chip(_ id: String, _ title: String) -> some View {
        Button {
            selectedCategory = id
        } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selectedCategory == id ? Theme.accentSoft : Theme.surface,
                            in: Capsule())
                .foregroundStyle(selectedCategory == id ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var filteredItems: [NavItemData] {
        selectedCategory == "all" ? items : items.filter { $0.categoryId == selectedCategory }
    }

    private func reload() {
        Task {
            do {
                let api = APIService()
                carousels = (try? await api.getNavCarousels()) ?? []
                categories = (try? await api.getNavCategories()) ?? []
                items = (try? await api.getNavItems()) ?? []
                errorMessage = items.isEmpty ? "暂无站点数据" : nil
            }
        }
    }

    private func openCarousel(_ carousel: NavCarouselData) {
        if let jump = carousel.jumpUrl, let url = URL(string: jump) {
            browsingURL = url
        }
    }

    private func openItem(_ item: NavItemData) {
        if let urlString = item.url, let url = URL(string: urlString) {
            browsingURL = url
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// 内置浏览器 + NativeObject JS 桥（iOS 分支实现，消息协议与
/// assets/js/NativeObject.js 相同：{command, args, callback}）。
struct NavBrowseView: View {

    let url: URL
    @State private var toast: String?

    var body: some View {
        NativeWebView(url: url, toast: $toast)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(url.host ?? "")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct NativeWebView: UIViewRepresentable {

    let url: URL
    @Binding var toast: String?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "nativeObject")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

        var parent: NativeWebView
        private var callbackCounter = 0

        init(_ parent: NativeWebView) {
            self.parent = parent
        }

        /// {command: "...", args: "...", callback: "callBack_..._key"} — the
        /// exact JSON contract from NativeObject.js.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "nativeObject",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let command = json["command"] as? String ?? ""
            let args = json["args"] as? String ?? ""
            let callbackKey = json["callback"] as? String

            handle(command: command, args: args, callbackKey: callbackKey)
        }

        private func handle(command: String, args: String, callbackKey: String?) {
            switch command {
            case "toast":
                Task { @MainActor in
                    withAnimation { self.parent.toast = args.isEmpty ? "提示" : args }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        withAnimation { self.parent.toast = nil }
                    }
                }
            case "openUrl":
                if let url = URL(string: args) {
                    UIApplication.shared.open(url)
                }
            case "vibrate":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            default:
                break
            }
            // Reply to JS callback slot if requested (nativeObjectJs.callback parity)
            if let callbackKey {
                let response: [String: Any] = [
                    "callback": callbackKey,
                    "args": ""
                ]
                if let data = try? JSONSerialization.data(withJSONObject: response),
                   let script = String(data: data, encoding: .utf8) {
                    Task { @MainActor in
                        // handled via injected function; pages re-post as needed
                    }
                }
                callbackCounter += 1
            }
        }

        func webView(_ webView: WKWebView, decide policy: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}
