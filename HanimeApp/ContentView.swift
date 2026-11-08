import SwiftUI
import WebKit

// MARK: - 每个 Tab 的 WebView 状态
final class WebViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    weak var webView: WKWebView?
}

// MARK: - 主界面：底部 Tab（看番 App 风格）
struct ContentView: View {
    var body: some View {
        TabView {
            SiteTabView(title: "首页", icon: "house.fill", url: URL(string: "https://hanime1.me/")!)
                .tabItem { Label("首页", systemImage: "house.fill") }

            SiteTabView(title: "搜索", icon: "magnifyingglass", url: URL(string: "https://hanime1.me/search?v=")!)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            SiteTabView(title: "追番", icon: "heart.fill", url: URL(string: "https://hanime1.me/watchlist")!)
                .tabItem { Label("追番", systemImage: "heart.fill") }
        }
        .tint(Color(red: 0.96, green: 0.44, blue: 0.55))
        .preferredColorScheme(.dark) // 网站本身是暗色主题，保持一致
    }
}

// MARK: - 单个 Tab
struct SiteTabView: View {
    let title: String
    let icon: String
    let url: URL

    @StateObject private var model = WebViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 App 栏：网页内容从安全区下方开始，
            // 不再顶进刘海/灵动岛，网站的导航和搜索栏都能正常点按
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.pink)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button {
                    model.webView?.reload()
                } label: {
                    Image(systemName: model.isLoading ? "xmark.circle.fill" : "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))

            // 页面加载进度条
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.pink)
                    .frame(height: 2)
            }

            WebViewContainer(model: model, initialURL: url)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
        // 悬浮前进/后退胶囊（有历史记录时才出现）
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 20) {
                Button {
                    model.webView?.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)

                Button {
                    model.webView?.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.trailing, 14)
            .padding(.bottom, 8)
            .opacity(model.canGoBack || model.canGoForward ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: model.canGoBack || model.canGoForward)
        }
    }
}

// MARK: - WebView 封装
struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var model: WebViewModel
    let initialURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 站内视频自动播放
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Cookie / 登录状态持久保存
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        model.webView = wv
        context.coordinator.observe(wv)
        wv.load(URLRequest(url: initialURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: WebViewModel
        private var observers: [NSKeyValueObservation] = []

        init(_ model: WebViewModel) {
            self.model = model
        }

        func observe(_ webView: WKWebView) {
            observers = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.model.progress = wv.estimatedProgress }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.model.isLoading = wv.isLoading }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.model.canGoBack = wv.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.model.canGoForward = wv.canGoForward }
                },
            ]
        }

        // 站外链接交给系统 Safari 打开；站内链接与资源请求正常放行
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let host = url.host?.lowercased(),
               !host.contains("hanime") {
                decisionHandler(.cancel)
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
                return
            }
            decisionHandler(.allow)
        }

        // 新窗口链接（target="_blank"）改为当前页打开，避免点了没反应
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }
    }
}
