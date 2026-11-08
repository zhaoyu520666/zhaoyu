import SwiftUI
import WebKit

// MARK: - 站点底部导航项（对应网站自带底栏）
struct SiteTab: Identifiable, Equatable {
    let id: Int
    let label: String       // 同时用于在网页 DOM 中定位同名导航项
    let icon: String
    let fallback: URL
}

let siteTabs: [SiteTab] = [
    SiteTab(id: 0, label: "主页", icon: "house.fill",
            fallback: URL(string: "https://hanime1.me/")!),
    SiteTab(id: 1, label: "本日排行", icon: "rectangle.stack.fill",
            fallback: URL(string: "https://hanime1.me/")!),
    SiteTab(id: 2, label: "订阅内容", icon: "play.rectangle.fill",
            fallback: URL(string: "https://hanime1.me/")!),
    SiteTab(id: 3, label: "我的", icon: "person.crop.square.fill",
            fallback: URL(string: "https://hanime1.me/")!),
]

// MARK: - WebView 状态
final class WebViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentTab: Int = 0
    weak var webView: WKWebView?
}

// MARK: - 主界面
struct ContentView: View {
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var model = WebViewModel()
    @State private var showDownloads = false

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(
                title: "Hanime",
                icon: "play.rectangle.fill",
                isLoading: model.isLoading,
                onReload: { model.webView?.reload() },
                extraIcon: "arrow.down.circle",
                onExtra: { showDownloads = true }
            )

            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.pink)
                    .frame(height: 2)
            }

            WebViewContainer(model: model, initialURL: siteTabs[0].fallback)

            BottomNavBar(model: model) { tab in
                navigate(to: tab)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let toast = downloads.toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: downloads.toast)
        .fullScreenCover(isPresented: $showDownloads) {
            DownloadsTabView(onClose: { showDownloads = false })
        }
    }

    /// 用网站自己的底栏地址跳转，找不到时退回首页
    private func navigate(to tab: SiteTab) {
        model.currentTab = tab.id
        let js = "window.__hnNav ? window.__hnNav('\(tab.label)') : '';"
        model.webView?.evaluateJavaScript(js) { result, _ in
            if let href = result as? String, !href.isEmpty, href != "clicked",
               let url = URL(string: href) {
                model.webView?.load(URLRequest(url: url))
            } else if let res = result as? String, res == "clicked" {
                // 站内脚本自行处理了跳转
            } else {
                model.webView?.load(URLRequest(url: tab.fallback))
            }
        }
    }
}

// MARK: - 顶部栏
struct TabHeader: View {
    let title: String
    let icon: String
    var isLoading: Bool = false
    var onReload: (() -> Void)? = nil
    var extraIcon: String? = nil
    var onExtra: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.pink)
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            if let onReload = onReload {
                Button(action: onReload) {
                    Image(systemName: isLoading ? "xmark.circle.fill" : "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            if let extraIcon = extraIcon, let onExtra = onExtra {
                Button(action: onExtra) {
                    Image(systemName: extraIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }
}

// MARK: - 底部原生导航栏（主页 / 本日排行 / 订阅内容 / 我的 + 前进后退）
struct BottomNavBar: View {
    @ObservedObject var model: WebViewModel
    var onSelect: (SiteTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(siteTabs) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .medium))
                        Text(tab.label)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(model.currentTab == tab.id ? .white : Color(white: 0.55))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1, height: 24)

            HStack(spacing: 16) {
                Button {
                    model.webView?.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.canGoBack ? .white : Color(white: 0.35))
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .disabled(!model.canGoBack)

                Button {
                    model.webView?.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.canGoForward ? .white : Color(white: 0.35))
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .disabled(!model.canGoForward)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
        }
        .frame(height: 54)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14).ignoresSafeArea(edges: .bottom))
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
        // 广告拦截脚本（含弹窗拦截、广告元素隐藏、底部导航接管）
        config.userContentController.addUserScript(
            WKUserScript(source: AdBlocker.bootstrapJS,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false)
        )

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

        // MARK: 导航策略：拦广告跳转 + 媒体直链转下载
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if scheme.isEmpty || scheme == "about" || scheme == "blob" || scheme == "data" {
                decisionHandler(.allow)
                return
            }

            // 0) 网页脚本标记的"用户下载意图"跳转：hnapp://open?url=<encoded>
            if scheme == "hnapp" {
                decisionHandler(.cancel)
                handleAppScheme(url, webView: webView)
                return
            }

            // 1) 视频/媒体直链 → 交给下载器，并用视频标题命名
            if DownloadManager.isDirectMediaURL(url) {
                decisionHandler(.cancel)
                startDownload(url: url, webView: webView)
                return
            }

            // 2) 广告域名 → 直接丢弃，不跳转、不开 Safari
            if AdBlocker.isAdURL(url) {
                decisionHandler(.cancel)
                return
            }

            let host = (url.host ?? "").lowercased()
            let isSite = host.contains("hanime")

            // 3) 站外地址
            if !isSite {
                if navigationAction.navigationType == .linkActivated && navigationAction.targetFrame != nil {
                    // 用户自己点的外链，交给系统浏览器（正常浏览行为）
                    decisionHandler(.cancel)
                    DispatchQueue.main.async { UIApplication.shared.open(url) }
                } else {
                    // JS 重定向 / 隐藏广告层触发的强制跳转：静默拦掉
                    decisionHandler(.cancel)
                }
                return
            }

            decisionHandler(.allow)
        }

        /// 解析 hnapp://open?url=<encoded>：媒体直链转下载，其余当作用户主动访问的页面
        private func handleAppScheme(_ url: URL, webView: WKWebView) {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: raw) else { return }
            if AdBlocker.isAdURL(target) { return }
            if DownloadManager.isDirectMediaURL(target) {
                startDownload(url: target, webView: webView)
            } else {
                // 下载中转页等：在当前页打开，若返回的是文件会再被转成交给下载器
                webView.load(URLRequest(url: target))
            }
        }

        /// 用当前视频页的标题作为文件名
        private func startDownload(url: URL, webView: WKWebView) {
            let js = #"""
            (function () {
              function clean(s) { return (s || "").replace(/\s+/g, " ").trim(); }
              var t = "";
              var h1 = document.querySelector("h1");
              if (h1 && clean(h1.innerText).length > 1) { t = clean(h1.innerText); }
              if (!t) {
                var og = document.querySelector('meta[property="og:title"]');
                if (og && og.content) { t = clean(og.content); }
              }
              if (!t) { t = clean(document.title); }
              return t;
            })();
            """#
            webView.evaluateJavaScript(js) { result, _ in
                let raw = (result as? String) ?? ""
                let title = raw.isEmpty ? webView.title : raw
                DownloadManager.shared.startDownload(from: url, webView: webView, title: title)
            }
        }

        // 服务器返回不可显示的文件（octet-stream / video 等）→ 转交下载
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
            if navigationResponse.canShowMIMEType == false
                || mime.contains("video")
                || mime.contains("octet-stream") {
                if let url = navigationResponse.response.url {
                    decisionHandler(.cancel)
                    startDownload(url: url, webView: webView)
                    return
                }
            }
            decisionHandler(.allow)
        }

        // 站内 target="_blank" 改在当前页打开；新窗口里的媒体直链直接下载；站外新窗口一律不创建
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if DownloadManager.isDirectMediaURL(url) {
                    startDownload(url: url, webView: webView)
                    return nil
                }
                if let host = url.host?.lowercased(),
                   host.contains("hanime"),
                   !AdBlocker.isAdURL(url) {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }
    }
}
