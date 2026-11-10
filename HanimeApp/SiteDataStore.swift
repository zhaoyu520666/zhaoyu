import Foundation
import UIKit
import WebKit

// MARK: - 数据模型
struct VideoItem: Identifiable, Equatable {
    var title: String
    var cover: String
    var url: String
    var id: String { url }

    var coverURL: URL? {
        var c = cover
        if c.hasPrefix("//") { c = "https:" + c }
        return URL(string: c)
    }
    var pageURL: URL? {
        var u = url
        if u.hasPrefix("/") { u = "https://hanime1.me" + u }
        return URL(string: u)
    }
}

struct VideoSource: Identifiable, Equatable {
    var label: String
    var url: String
    var id: String { url }
}

struct VideoDetail {
    var title: String
    var cover: String
    var desc: String
    var tags: [String]
    var sources: [VideoSource]
    var watchURL: String
}

enum SiteDataError: LocalizedError {
    case timeout
    case empty
    case badResponse

    var errorDescription: String? {
        switch self {
        case .timeout: return "加载超时，请重试"
        case .empty: return "没有取到内容（可能需要登录，或网络不佳）"
        case .badResponse: return "页面数据解析失败"
        }
    }
}

// MARK: - 注入网页的数据提取脚本
enum Extractors {

    /// 列表页：抓取所有 /watch?v= 卡片 + 顺带提取网站底部导航真实地址（一次页面加载拿全部数据）
    static let list: String = ##"""
    (function () {
      function clean(s) { return (s || "").replace(/\s+/g, " ").trim(); }
      function tidy(t) {
        return (t || "")
          .replace(/^\s*\d{1,2}:\d{2}\s*/, "")
          .replace(/thumb_up|thumb_down/gi, " ")
          .replace(/\d+(\.\d+)?%/g, " ")
          .replace(/\d+(\.\d+)?万次/g, " ")
          .replace(/\s+/g, " ").trim();
      }
      function find(label) {
        var all = document.querySelectorAll("a, button, li, div, span");
        var best = null, bl = 999, bw = 1e9;
        for (var i = 0; i < all.length; i++) {
          var t = (all[i].innerText || "").replace(/\s+/g, " ").trim();
          if (!t || t.length > 14 || t.indexOf(label) === -1) { continue; }
          var w = all[i].getBoundingClientRect().width;
          if (t.length < bl || (t.length === bl && w < bw)) { best = all[i]; bl = t.length; bw = w; }
        }
        return best;
      }
      function href(label) {
        var el = find(label);
        var a = el && el.closest ? el.closest("a") : null;
        return (a && a.href) ? a.href : "";
      }
      var nav = { home: href("主页"), rank: href("本日排行"), subs: href("订阅内容"), mine: href("我的") };
      var items = [], seen = {};
      var anchors = document.querySelectorAll('a[href*="watch?v="]');
      for (var i = 0; i < anchors.length; i++) {
        var a = anchors[i];
        var hrefAttr = a.href || a.getAttribute("href") || "";
        if (hrefAttr.charAt(0) === "/") { hrefAttr = location.origin + hrefAttr; }
        if (hrefAttr.indexOf("watch?v=") === -1 || seen[hrefAttr]) { continue; }
        var card = a.closest("div") || a;
        var img = a.querySelector("img") || card.querySelector("img");
        var title = tidy(clean((img && (img.alt || img.title)) || ""));
        if (!title) { title = tidy(clean(a.innerText)); }
        if (!title) { title = tidy(clean(card.innerText)).slice(0, 60); }
        var cover = img ? (img.getAttribute("src") || img.getAttribute("data-src") || img.getAttribute("data-original") || "") : "";
        if (cover.indexOf("//") === 0) { cover = "https:" + cover; }
        if (!title || title.length < 2) { continue; }
        seen[hrefAttr] = 1;
        items.push({ title: title.slice(0, 100), cover: cover, url: hrefAttr });
        if (items.length >= 80) { break; }
      }
      return JSON.stringify({ ok: items.length > 0, items: items, nav: nav });
    })();
    """##

    /// 视频详情页：标题 / 封面 / 简介 / 标签 / m3u8·mp4 播放地址
    /// 播放器常在内嵌 iframe（embed 页）里，主页面扫不到时用同源 fetch 抓 iframe 页面再扫
    static let watch: String = ##"""
    (function () {
      function clean(s) { return (s || "").replace(/\s+/g, " ").trim(); }
      function grab(text) {
        var raw = (text || "").replace(/\\\//g, "/");
        return raw.match(/https?:\/\/[^\s"'<>\\]+?\.(?:m3u8|mp4)(?:\?[^"'<>\\\s]*)?/g) || [];
      }
      function og(name) {
        var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
        return el ? clean(el.getAttribute("content")) : "";
      }
      function tidy(t) {
        return (t || "")
          .replace(/^\s*\d{1,2}:\d{2}\s*/, "")
          .replace(/thumb_up|thumb_down/gi, " ")
          .replace(/\d+(\.\d+)?%/g, " ")
          .replace(/\d+(\.\d+)?万次/g, " ")
          .replace(/\s+/g, " ").trim();
      }
      function meta() {
        var h1 = document.querySelector("h1");
        var title = tidy(clean((h1 && h1.innerText) || "") || og("og:title") || clean(document.title));
        var tags = [];
        var tagAs = document.querySelectorAll('a[href*="search?query="], a[href*="genre"], .genre a, .tags a, .tag');
        for (var j = 0; j < tagAs.length && tags.length < 12; j++) {
          var t = clean(tagAs[j].innerText);
          if (t && t.length <= 20 && tags.indexOf(t) < 0) { tags.push(t); }
        }
        return { title: title, cover: og("og:image"), desc: og("og:description") || og("description"), tags: tags };
      }
      function dedupe(arr) {
        var uniq = [], seen = {};
        for (var i = 0; i < arr.length; i++) { if (!seen[arr[i]]) { seen[arr[i]] = 1; uniq.push(arr[i]); } }
        return uniq;
      }
      return new Promise(function (resolve) {
        var tries = 0;
        var iframeSrcs = [];
        function attempt() {
          tries++;
          var found = grab(document.documentElement.innerHTML);
          var iframes = document.querySelectorAll("iframe");
          iframeSrcs = [];
          for (var i = 0; i < iframes.length; i++) {
            var s = iframes[i].src || "";
            if (s.indexOf(location.origin) === 0 && s !== location.href) { iframeSrcs.push(s); }
          }
          if (found.length === 0 && tries < 5) { setTimeout(attempt, 1500); return; }
          fetchEmbeds(found);
        }
        function fetchEmbeds(found) {
          var list = iframeSrcs.slice(0, 3);
          var done = 0;
          if (list.length === 0) { finish(found); return; }
          list.forEach(function (u) {
            fetch(u, { credentials: "include" })
              .then(function (r) { return r.text(); })
              .then(function (t) { found = found.concat(grab(t)); })
              .catch(function () {})
              .then(function () { done++; if (done >= list.length) { finish(found); } });
          });
        }
        function finish(found) {
          var uniq = dedupe(found);
          var mm = meta();
          resolve(JSON.stringify({ ok: uniq.length > 0, title: mm.title, cover: mm.cover, desc: mm.desc, tags: mm.tags, sources: uniq, watchURL: location.href }));
        }
        attempt();
      });
    })();
    """##

    /// 媒体请求监听：在页面 DOC 开始时注入（含 iframe），
    /// 拦截 XHR/fetch/video 实际请求的 m3u8·mp4 地址，回传给原生层。
    /// 这是最可靠的取流方式——不依赖播放器把地址写在 HTML 里。
    static let mediaCapture: String = ##"""
    (function () {
      if (window.__hnHooked) { return; }
      window.__hnHooked = 1;
      function abs(u) {
        if (!u) { return ""; }
        if (u.indexOf("//") === 0) { return "https:" + u; }
        if (u.charAt(0) === "/") { return location.origin + u; }
        return u;
      }
      function send(u) {
        try {
          var s = abs(String(u || ""));
          if (!/m3u8|mp4/i.test(s)) { return; }
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hnMedia) {
            window.webkit.messageHandlers.hnMedia.postMessage({ url: s });
          }
        } catch (e) {}
      }
      try {
        var originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { send(url); } catch (e) {}
          return originalOpen.apply(this, arguments);
        };
      } catch (e) {}
      try {
        if (window.fetch) {
          var originalFetch = window.fetch;
          window.fetch = function (input) {
            try { send(typeof input === "string" ? input : (input && input.url)); } catch (e) {}
            return originalFetch.apply(this, arguments);
          };
        }
      } catch (e) {}
      function scan() {
        try {
          var nodes = document.querySelectorAll("video, source, a[href*='.mp4'], a[href*='.m3u8']");
          for (var i = 0; i < nodes.length; i++) {
            var v = nodes[i];
            send(v.src || v.getAttribute("src") || v.getAttribute("href") || "");
          }
        } catch (e) {}
      }
      scan();
      setInterval(scan, 1500);
    })();
    """##
}

// MARK: - 数据引擎（隐藏 WebView + 串行队列 + 缓存）
final class SiteDataStore: NSObject, ObservableObject {
    static let shared = SiteDataStore()

    @Published var navLinks: [String: String] = [:]
    @Published var revision = 0   // 外部刷新按钮触发：清缓存 + 让网格重载

    private var webView: WKWebView?
    private var queue: [PendingFetch] = []
    private var busy = false
    private var cache: [String: (date: Date, payload: String)] = [:]
    private var appliedBlockRules = false
    /// 页面实际请求到的媒体地址（由注入脚本回传），按页面累积
    private var capturedSources: [String] = []

    private func takeCaptured() -> [String] {
        let list = capturedSources
        capturedSources = []
        return list
    }

    private struct PendingFetch {
        let url: URL
        let name: String
        let extractor: String
        let completion: (Result<String, Error>) -> Void
    }

    let homeURL = URL(string: "https://hanime1.me/")!
    var rankURL: URL { navLink("rank") ?? homeURL }
    var subsURL: URL { navLink("subs") ?? homeURL }

    private func navLink(_ key: String) -> URL? {
        guard let s = navLinks[key], !s.isEmpty, let u = URL(string: s) else { return nil }
        return u
    }

    // MARK: 轻量加载规则：隐藏 WebView 只需要 HTML DOM，图片/样式/字体/媒体一律拦截
    private static var blockRules: WKContentRuleList?
    private static func compileBlockRules() {
        guard blockRules == nil else { return }
        let json = """
        [{"trigger":{"url-filter":".*","resource-type":["image","stylesheet","font"]},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "data-light",
            encodedContentRuleList: json
        ) { list, _ in
            blockRules = list
        }
    }

    private func applyBlockRulesIfNeeded() {
        guard !appliedBlockRules, let rules = Self.blockRules, let wv = webView else { return }
        wv.configuration.userContentController.add(rules)
        appliedBlockRules = true
    }

    // MARK: 对外接口

    /// 启动：编译轻量规则 + 就绪隐藏 WebView（导航地址随首次列表页一并取出）
    func activate() {
        Self.compileBlockRules()
        ensureWebView()
    }

    func clearCache() {
        cache.removeAll()
        revision += 1
    }

    func fetchList(_ url: URL, completion: @escaping (Result<[VideoItem], Error>) -> Void) {
        run(url, name: "list", extractor: Extractors.list) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                guard let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(ListPayload.self, from: data) else {
                    completion(.failure(SiteDataError.badResponse)); return
                }
                // 顺带更新导航真实地址（列表脚本每次都会带出来）
                if let nav = payload.nav {
                    var links = self.navLinks
                    if let s = nav.home, !s.isEmpty { links["home"] = s }
                    if let s = nav.rank, !s.isEmpty { links["rank"] = s }
                    if let s = nav.subs, !s.isEmpty { links["subs"] = s }
                    if let s = nav.mine, !s.isEmpty { links["mine"] = s }
                    if links != self.navLinks {
                        self.navLinks = links
                        self.objectWillChange.send()
                    }
                }
                let items = payload.items.map { VideoItem(title: $0.title, cover: $0.cover, url: $0.url) }
                completion(.success(items))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchDetail(_ url: URL, completion: @escaping (Result<VideoDetail, Error>) -> Void) {
        run(url, name: "watch", extractor: Extractors.watch) { [weak self] result in
            switch result {
            case .success(let json):
                guard let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(WatchPayload.self, from: data) else {
                    completion(.failure(SiteDataError.badResponse)); return
                }
                // 合并「页面实际请求到的媒体地址」（最可靠的来源）与 HTML 里扫到的地址
                var merged = payload.sources
                if let captured = self?.takeCaptured(), !captured.isEmpty {
                    merged.append(contentsOf: captured)
                }
                // m3u8（自适应流，AVPlayer 直接支持）排前面；mp4 按清晰度数字从高到低
                let sorted = merged.sorted { a, b in
                    let aHLS = a.contains(".m3u8"), bHLS = b.contains(".m3u8")
                    if aHLS != bHLS { return aHLS }
                    func res(_ s: String) -> Int {
                        for h in [1080, 720, 480, 360, 240, 144] where s.contains(String(h)) { return h }
                        return 0
                    }
                    if res(a) != res(b) { return res(a) > res(b) }
                    return false
                }
                let sources: [VideoSource] = sorted.enumerated().map { (idx, u) in
                    VideoSource(label: Self.sourceLabel(u, index: idx), url: u)
                }
                guard !sources.isEmpty else {
                    completion(.failure(SiteDataError.empty)); return
                }
                completion(.success(VideoDetail(
                    title: payload.title ?? "",
                    cover: payload.cover ?? "",
                    desc: payload.desc ?? "",
                    tags: payload.tags ?? [],
                    sources: sources,
                    watchURL: payload.watchURL ?? url.absoluteString
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 从播放地址猜清晰度标签
    static func sourceLabel(_ u: String, index: Int) -> String {
        for h in ["1080", "720", "480", "360", "240", "144"] where u.contains(h) {
            return "\(h)P"
        }
        return "线路 \(index + 1)"
    }

    // MARK: 队列与隐藏 WebView

    private func ensureWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 与登录页共享 Cookie
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []   // 让播放器能自动初始化拉流
        let controller = config.userContentController
        controller.add(self, name: "hnMedia")
        controller.addUserScript(WKUserScript(
            source: Extractors.mediaCapture,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let wv = WKWebView(frame: CGRect(x: -400, y: -400, width: 400, height: 900), configuration: config)
        wv.navigationDelegate = self
        webView = wv
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.first?.windows.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first {
                window.addSubview(wv)
            }
        }
    }

    private func run(_ url: URL, name: String, extractor: String,
                     skipCache: Bool = false,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let key = url.absoluteString + "#" + name
        if !skipCache, let c = cache[key], Date().timeIntervalSince(c.date) < 300 {
            completion(.success(c.payload))
            return
        }
        ensureWebView()
        applyBlockRulesIfNeeded()
        queue.append(PendingFetch(url: url, name: name, extractor: extractor, completion: completion))
        pump()
    }

    private func pump() {
        guard !busy, let next = queue.first, let wv = webView else { return }
        busy = true
        queue.removeFirst()
        current = next
        capturedSources = []   // 每个页面只保留自己抓到的媒体地址
        applyBlockRulesIfNeeded()
        wv.stopLoading()
        wv.load(URLRequest(url: next.url, timeoutInterval: 30))
        startWatchdog()
    }

    // 超时兜底：页面迟迟加载不完 / 提取脚本挂起时，强制结束当前任务，避免 UI 永远"解析中"
    private var watchdog: DispatchWorkItem?
    private func startWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.current != nil else { return }
            self.finish(.failure(SiteDataError.timeout))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        watchdog = work
    }

    private func finish(_ result: Result<String, Error>) {
        watchdog?.cancel()
        watchdog = nil
        guard let cur = current else { busy = false; return }
        current = nil
        busy = false
        if case .success(let json) = result {
            cache[cur.url.absoluteString + "#" + cur.name] = (Date(), json)
        }
        cur.completion(result)
        pump()
    }

    private var current: PendingFetch?

    private struct NavLinks: Decodable {
        let home: String?; let rank: String?; let subs: String?; let mine: String?
    }

    private struct ListPayload: Decodable {
        let ok: Bool
        let items: [RawItem]
        let nav: NavLinks?
        struct RawItem: Decodable { let title: String; let cover: String; let url: String }
    }

    private struct WatchPayload: Decodable {
        let ok: Bool
        let title: String?
        let cover: String?
        let desc: String?
        let tags: [String]?
        let sources: [String]
        let watchURL: String?
    }
}

// MARK: - 导航代理：加载完成 → 提取
extension SiteDataStore: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let cur = current else { return }

        // Cloudflare 挑战页：等几秒让验证自动通过再提取
        webView.evaluateJavaScript(
            "(function(){var t=(document.body?document.body.innerText:'');return /just a moment|attention required|cf-chl|checking your browser/i.test(t)?'1':'0';})()"
        ) { [weak self] res, _ in
            DispatchQueue.main.async {
                guard let self = self, self.current != nil else { return }
                if (res as? String) == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self = self, self.current != nil else { return }
                        self.extract(cur, in: webView, attempt: 0)
                    }
                } else {
                    self.extract(cur, in: webView, attempt: 0)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SiteDataError.timeout))
    }

    private func extract(_ pending: PendingFetch, in webView: WKWebView, attempt: Int) {
        webView.evaluateJavaScript(pending.extractor) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self = self, self.current != nil else { return }
                guard let json = result as? String else {
                    self.finish(.failure(SiteDataError.empty))
                    return
                }
                // ok:false 可能是内容还没渲染好 / 播放器还没拉流，多等几轮（同时等媒体请求回传）
                let looksEmpty = json.contains("\"ok\":false")
                if looksEmpty && attempt < 5 && self.capturedSources.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self, self.current != nil else { return }
                        self.extract(pending, in: webView, attempt: attempt + 1)
                    }
                    return
                }
                self.finish(.success(json))
            }
        }
    }
}

// MARK: - 媒体请求回传（注入脚本 → 原生层）
extension SiteDataStore: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "hnMedia",
              let body = message.body as? [String: Any],
              let url = body["url"] as? String,
              !url.isEmpty,
              !capturedSources.contains(url) else { return }
        capturedSources.append(url)
        if capturedSources.count > 40 { capturedSources.removeFirst() }
    }
}
