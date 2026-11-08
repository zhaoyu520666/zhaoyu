import SwiftUI
import WebKit

struct ContentView: View {
    @State private var webView: WKWebView?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            WebViewContainer(
                webView: $webView,
                onStateChange: { back, forward, loading in
                    canGoBack = back
                    canGoForward = forward
                    isLoading = loading
                }
            )
            .ignoresSafeArea(edges: .top)

            // 底部工具栏：返回 / 刷新 / 前进
            HStack(spacing: 48) {
                Button {
                    webView?.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18))
                }
                .disabled(!canGoBack)

                Button {
                    webView?.reload()
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 18))
                }

                Button {
                    webView?.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18))
                }
                .disabled(!canGoForward)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    @Binding var webView: WKWebView?
    var onStateChange: (Bool, Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 允许网页内自动播放视频（站内视频体验需要）
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.scrollView.contentInsetAdjustmentBehavior = .never

        if let url = URL(string: "https://hanime1.me/") {
            wv.load(URLRequest(url: url))
        }
        DispatchQueue.main.async { self.webView = wv }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewContainer

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onStateChange(webView.canGoBack, webView.canGoForward, true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onStateChange(webView.canGoBack, webView.canGoForward, false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onStateChange(webView.canGoBack, webView.canGoForward, false)
        }

        // 站外链接交给系统 Safari 打开；站内链接与资源请求（iframe、视频等）正常放行
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
    }
}
