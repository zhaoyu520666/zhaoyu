import UIKit
import WebKit

// MARK: - 不可见抓取引擎
// 用 1x1 屏幕外 WKWebView 以真实 WebKit 身份取回页面 HTML（用于绕过 Cloudflare 对原生 URLSession 的指纹拦截），
// 取回的是纯字符串，由 SiteAPI 用正则解析，界面全程原生、不渲染任何网页内容。
final class HTMLFetcher: NSObject, WKNavigationDelegate {

    static let shared = HTMLFetcher()

    struct Job {
        let url: URL
        let readySelector: String?   // 轮询直到该选择器命中（说明页面真实内容已渲染）
        let maxWait: TimeInterval
        let completion: (Result<String, Error>) -> Void
    }

    private var webView: WKWebView?
    private var queue: [Job] = []
    private var current: Job?
    private var pollTimer: Timer?
    private var watchdog: DispatchWorkItem?
    private var startedAt = Date()
    private var preparing = false

    /// 最近一次抓取的诊断信息（出问题时显示在界面上）
    private(set) var lastDiagnostics = ""

    private override init() { super.init() }

    // MARK: 对外接口
    func fetch(_ url: URL, readySelector: String?, maxWait: TimeInterval = 15,
               completion: @escaping (Result<String, Error>) -> Void) {
        onMain {
            self.queue.append(Job(url: url, readySelector: readySelector, maxWait: maxWait, completion: completion))
            self.pump()
        }
    }

    /// 原生登录：在抓取引擎里填表单并提交（同源提交，真实浏览器行为）
    func login(email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let loginURL = URL(string: SiteAPI.base + "/login") else {
            completion(.failure(SiteDataError.badResponse)); return
        }
        fetch(loginURL, readySelector: "input[name=\"email\"]", maxWait: 12) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success:
                let js = """
                (function(){
                  function setv(el,v){
                    el.focus(); el.value=v;
                    el.dispatchEvent(new Event('input',{bubbles:true}));
                    el.dispatchEvent(new Event('change',{bubbles:true}));
                  }
                  var f = document.querySelector('form[action*="login"]') || document.forms[0];
                  var e = document.querySelector('input[name="email"]');
                  var p = document.querySelector('input[name="password"]');
                  if(!f || !e || !p){ return 'noform'; }
                  setv(e, \(HTMLFetcher.jsString(email)));
                  setv(p, \(HTMLFetcher.jsString(password)));
                  f.submit();
                  return 'submitted';
                })();
                """
                self.onMain {
                    self.webView?.evaluateJavaScript(js) { value, _ in
                        let status = value as? String ?? ""
                        if status == "noform" {
                            completion(.failure(SiteDataError.loginFailed("登录表单结构变化，请反馈")))
                            return
                        }
                        // 提交后等 3 秒看落点 URL：还在 /login 说明失败
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.webView?.evaluateJavaScript("location.href") { href, _ in
                                let h = (href as? String) ?? ""
                                if h.contains("/login") || h.isEmpty {
                                    completion(.failure(SiteDataError.loginFailed("邮箱或密码错误")))
                                } else {
                                    completion(.success(()))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 清除登录 Cookie（webview + 原生 cookie 存储）
    func clearCookies() {
        onMain {
            let store = WKWebsiteDataStore.default()
            store.httpCookieStore.getAllCookies { cookies in
                for c in cookies where c.domain.contains("hanime1") {
                    store.httpCookieStore.delete(c)
                    HTTPCookieStorage.shared.deleteCookie(c)
                }
            }
        }
        if let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: SiteAPI.base)!) {
            for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
        }
    }

    // MARK: 调度
    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        if webView == nil {
            prepareEngine { [weak self] in self?.pump() }
            return
        }
        let job = queue.removeFirst()
        current = job
        startedAt = Date()
        guard let wv = webView else { return }
        var request = URLRequest(url: job.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(SiteAPI.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        wv.load(request)
        scheduleWatchdog(job.maxWait + 6)
    }

    /// 编译资源拦截规则（屏蔽图片/媒体/字体，只为快速拿到 HTML），然后创建隐藏 WebView
    private func prepareEngine(_ done: @escaping () -> Void) {
        guard !preparing, webView == nil else { return }
        preparing = true
        let rules = """
        [{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "hanime.fetch.rules",
                                                                encodedContentRuleList: rules) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()      // 持久 Cookie：登录态 / Cloudflare 通行证
                config.defaultWebpagePreferences.allowsContentJavaScript = true
                if let list = list { config.userContentController.add(list) }
                let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 860), configuration: config)
                wv.navigationDelegate = self
                wv.customUserAgent = SiteAPI.mobileUA
                wv.isUserInteractionEnabled = false
                wv.alpha = 0.01
                wv.isOpaque = false
                self.webView = wv
                self.attachToWindow(wv)
                self.preparing = false
                done()
            }
        }
    }

    private func attachToWindow(_ wv: WKWebView) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            // 窗口还没准备好，稍后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak wv] in
                guard let wv = wv else { return }
                self?.attachToWindow(wv)
            }
            return
        }
        wv.removeFromSuperview()
        wv.frame = CGRect(x: -4, y: -4, width: 1, height: 1)
        window.addSubview(wv)
    }

    private func scheduleWatchdog(_ seconds: TimeInterval) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finish(reason: "超时", forced: true)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        startPolling()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(reason: "页面加载失败：\(error.localizedDescription)", forced: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(reason: "无法连接：\(error.localizedDescription)", forced: true)
    }

    // MARK: 轮询等待真实内容
    private func startPolling() {
        pollTimer?.invalidate()
        let expectedURL = current?.url
        let selector = current?.readySelector
        let maxWait = current?.maxWait ?? 14

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self, self.current != nil, self.current?.url == expectedURL else {
                timer.invalidate(); return
            }
            let elapsed = Date().timeIntervalSince(self.startedAt)

            let selJS: String
            if let selector = selector, !selector.isEmpty {
                selJS = "document.querySelectorAll(\(HTMLFetcher.jsString(selector))).length"
            } else {
                selJS = "0"
            }
            let js = """
            (function(){
              var n = 0;
              try { n = \(selJS); } catch(e) { n = 0; }
              return JSON.stringify({
                n: n,
                ready: document.readyState,
                title: document.title || '',
                url: location.href || ''
              });
            })();
            """
            self.webView?.evaluateJavaScript(js) { value, _ in
                guard let str = value as? String,
                      let data = str.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let info = obj as? [String: Any] else { return }
                let n = info["n"] as? Int ?? 0
                let ready = info["ready"] as? String ?? ""
                let title = info["title"] as? String ?? ""

                // 命中目标内容 → 立刻交付
                if selector != nil && n > 0 {
                    self.finish(reason: "ok", forced: false); return
                }
                // 无选择器要求：文档完成后再等 0.6 秒让脚本渲染
                if selector == nil && ready == "complete" && elapsed > 0.8 {
                    self.finish(reason: "ok", forced: false); return
                }
                // Cloudflare 验证页：继续等它自动通过
                if title.contains("Just a moment") || title.contains("Attention Required") {
                    if elapsed > maxWait { self.finish(reason: "验证未通过", forced: true) }
                    return
                }
                if elapsed > maxWait {
                    self.finish(reason: "等待内容超时", forced: true)
                }
            }
        }
    }

    // MARK: 收尾
    private func finish(reason: String, forced: Bool) {
        guard let job = current else { return }
        current = nil
        pollTimer?.invalidate()
        pollTimer = nil
        watchdog?.cancel()

        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, _ in
            let html = value as? String ?? ""
            guard let self = self else { return }
            self.webView?.evaluateJavaScript("JSON.stringify({u:location.href,t:document.title||''})") { meta, _ in
                var finalURL = job.url.absoluteString
                var title = ""
                if let s = meta as? String, let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d),
                   let info = obj as? [String: Any] {
                    finalURL = info["u"] as? String ?? finalURL
                    title = info["t"] as? String ?? ""
                }
                let snippet = String(html.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                self.lastDiagnostics = "页面：\(title)\n地址：\(finalURL)\nHTML：\(html.count) 字符\n状态：\(reason)\n开头：\(snippet)"
                DispatchQueue.main.async {
                    if html.count > 200 {
                        job.completion(.success(html))
                    } else if forced {
                        job.completion(.failure(SiteDataError.badResponse))
                    } else {
                        job.completion(.success(html))
                    }
                    self.pump()
                }
            }
        }
    }

    // MARK: 工具
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    static func jsString(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(out)\""
    }
}
