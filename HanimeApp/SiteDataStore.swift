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

    /// 列表页：抓取所有 /watch?v= 卡片（标题 + 封面）
    static let list: String = ##"""
    (function () {
      function clean(s) { return (s || "").replace(/\s+/g, " ").trim(); }
      var items = [], seen = {};
      var anchors = document.querySelectorAll('a[href*="watch?v="]');
      for (var i = 0; i < anchors.length; i++) {
        var a = anchors[i];
        var href = a.href || a.getAttribute("href") || "";
        if (href.charAt(0) === "/") { href = location.origin + href; }
        if (href.indexOf("watch?v=") === -1 || seen[href]) { continue; }
        var card = a.closest("div") || a;
        var img = a.querySelector("img") || card.querySelector("img");
        var title = clean((img && (img.alt || img.title)) || "");
        if (!title) { title = clean(a.innerText); }
        if (!title) { title = clean(card.innerText).slice(0, 60); }
        var cover = img ? (img.getAttribute("src") || img.getAttribute("data-src") || img.getAttribute("data-original") || "") : "";
        if (cover.indexOf("//") === 0) { cover = "https:" + cover; }
        if (!title || title.length < 2) { continue; }
        seen[href] = 1;
        items.push({ title: title.slice(0, 100), cover: cover, url: href });
        if (items.length >= 80) { break; }
      }
      return JSON.stringify({ ok: items.length > 0, items: items });
    })();
    """##

    /// 视频详情页：标题 / 封面 / 简介 / 标签 / m3u8·mp4 播放地址
    static let watch: String = ##"""
    (function () {
      function clean(s) { return (s || "").replace(/\s+/g, " ").trim(); }
      var raw = document.documentElement.innerHTML.replace(/\\\//g, "/");
      var matches = raw.match(/https?:\/\/[^\s"'<>\\]+?\.(?:m3u8|mp4)(?:\?[^"'<>\\\s]*)?/g) || [];
      var uniq = [], seen = {};
      for (var i = 0; i < matches.length; i++) {
        var u = matches[i];
        if (!seen[u]) { seen[u] = 1; uniq.push(u); }
      }
      function og(name) {
        var m = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
        return m ? clean(m.getAttribute("content")) : "";
      }
      var h1 = document.querySelector("h1");
      var title = clean((h1 && h1.innerText) || "") || og("og:title") || clean(document.title);
      var cover = og("og:image");
      var desc = og("og:description") || og("description");
      var tags = [];
      var tagAs = document.querySelectorAll('a[href*="search?query="], a[href*="genre"], .genre a, .tags a, .tag');
      for (var j = 0; j < tagAs.length && tags.length < 12; j++) {
        var t = clean(tagAs[j].innerText);
        if (t && t.length <= 20 && tags.indexOf(t) < 0) { tags.push(t); }
      }
      return JSON.stringify({
        ok: uniq.length > 0,
        title: title, cover: cover, desc: desc,
        tags: tags, sources: uniq, watchURL: location.href
      });
    })();
    """##

    /// 网站自带底部导航的真实跳转地址
    static let nav: String = ##"""
    (function () {
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
      return JSON.stringify({ home: href("主页"), rank: href("本日排行"), subs: href("订阅内容"), mine: href("我的") });
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

    // MARK: 对外接口

    /// 启动：建隐藏 WebView + 抓一次首页拿导航真实地址
    func activate() {
        ensureWebView()
        run(homeURL, name: "nav", extractor: Extractors.nav, skipCache: true) { [weak self] result in
            guard let self = self else { return }
            if case .success(let json) = result,
               let data = json.data(using: .utf8),
               let payload = try? JSONDecoder().decode(NavPayload.self, from: data) {
                var links: [String: String] = [:]
                if let s = payload.home, !s.isEmpty { links["home"] = s }
                if let s = payload.rank, !s.isEmpty { links["rank"] = s }
                if let s = payload.subs, !s.isEmpty { links["subs"] = s }
                if let s = payload.mine, !s.isEmpty { links["mine"] = s }
                self.navLinks = links
                self.objectWillChange.send()   // 让 rankURL/subsURL 重新求值
            }
        }
    }

    func clearCache() {
        cache.removeAll()
        revision += 1
    }

    func fetchList(_ url: URL, completion: @escaping (Result<[VideoItem], Error>) -> Void) {
        run(url, name: "list", extractor: Extractors.list) { result in
            switch result {
            case .success(let json):
                guard let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(ListPayload.self, from: data) else {
                    completion(.failure(SiteDataError.badResponse)); return
                }
                let items = payload.items.map { VideoItem(title: $0.title, cover: $0.cover, url: $0.url) }
                completion(.success(items))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchDetail(_ url: URL, completion: @escaping (Result<VideoDetail, Error>) -> Void) {
        run(url, name: "watch", extractor: Extractors.watch) { result in
            switch result {
            case .success(let json):
                guard let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(WatchPayload.self, from: data) else {
                    completion(.failure(SiteDataError.badResponse)); return
                }
                let sources: [VideoSource] = payload.sources.enumerated().map { (idx, u) in
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
        queue.append(PendingFetch(url: url, name: name, extractor: extractor, completion: completion))
        pump()
    }

    private func pump() {
        guard !busy, let next = queue.first, let wv = webView else { return }
        busy = true
        queue.removeFirst()
        current = next
        wv.stopLoading()
        wv.load(URLRequest(url: next.url, timeoutInterval: 30))
    }

    private func finish(_ result: Result<String, Error>) {
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

    private struct ListPayload: Decodable {
        let ok: Bool
        let items: [RawItem]
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

    private struct NavPayload: Decodable {
        let home: String?
        let rank: String?
        let subs: String?
        let mine: String?
    }
}

// MARK: - 导航代理：加载完成 → 提取
extension SiteDataStore: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let cur = current else { return }

        // Cloudflare 挑战页：等 5 秒让验证自动通过再提取
        webView.evaluateJavaScript(
            "(function(){var t=(document.body?document.body.innerText:'');return /just a moment|attention required|cf-chl|checking your browser/i.test(t)?'1':'0';})()"
        ) { [weak self] res, _ in
            DispatchQueue.main.async {
                guard let self = self, self.current != nil else { return }
                if (res as? String) == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
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
                guard let json = result as? String, let data = json.data(using: .utf8) else {
                    self.finish(.failure(SiteDataError.empty))
                    return
                }
                // ok:false 可能是内容还没渲染好，重试一次
                let looksEmpty = json.contains("\"ok\":false")
                if looksEmpty && attempt < 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        guard let self = self, self.current != nil else { return }
                        self.extract(pending, in: webView, attempt: attempt + 1)
                    }
                    return
                }
                self.finish(.success(json))
                _ = data
            }
        }
    }
}
