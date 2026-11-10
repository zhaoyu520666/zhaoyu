import SwiftUI
import WebKit

// MARK: - 可见网页容器（用于登录页、原生解析失败时的兜底）
struct WebSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WebViewModel()

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(
                title: "网页",
                icon: "safari",
                isLoading: model.isLoading,
                onReload: { model.webView?.reload() },
                extraIcon: "xmark",
                onExtra: { dismiss() }
            )
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.pink)
                    .frame(height: 2)
            }
            WebViewContainer(model: model, initialURL: url)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onDisappear {
            // 登录等操作完成后刷新原生数据（Cookie 已共享）
            SiteDataStore.shared.clearCache()
        }
    }
}

// MARK: - WebView 状态
final class WebViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    weak var webView: WKWebView?
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
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // 与隐藏数据 WebView / 登录共享 Cookie
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
                    decisionHandler(.cancel)
                    DispatchQueue.main.async { UIApplication.shared.open(url) }
                } else {
                    decisionHandler(.cancel)
                }
                return
            }

            decisionHandler(.allow)
        }

        /// 解析 hnapp://open?url=<encoded>
        private func handleAppScheme(_ url: URL, webView: WKWebView) {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: raw) else { return }
            if AdBlocker.isAdURL(target) { return }
            if DownloadManager.isDirectMediaURL(target) {
                startDownload(url: target, webView: webView)
            } else {
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
