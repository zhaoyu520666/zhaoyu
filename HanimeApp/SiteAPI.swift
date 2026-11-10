import Foundation

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
    case loginFailed(String)
    case needToken

    var errorDescription: String? {
        switch self {
        case .timeout: return "加载超时，请重试"
        case .empty: return "没有取到内容（可能需要登录，或网络不佳）"
        case .badResponse: return "页面数据解析失败"
        case .loginFailed(let reason): return reason
        case .needToken: return "登录页校验失败，请重试"
        }
    }
}

// MARK: - 纯原生数据引擎（URLSession 抓 HTML + Swift 正则解析，全程无 WebView）
final class SiteAPI: ObservableObject {
    static let shared = SiteAPI()

    static let base = "https://hanime1.me"
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    @Published var isLoggedIn = false
    @Published var checkingLogin = false
    @Published var lastDiagnostics = ""

    // 列表页特征选择器（页面真实内容已渲染的判定条件）
    static let listReadySelector = "a[href*=\"watch?v=\"]"
    static let detailReadySelector = "video, source[src]"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    /// 统一带上手机 UA 的请求
    func makeRequest(_ url: URL, referer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://hanime1.me/", forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer = referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    /// 首选：不可见 WebKit 抓取（真实浏览器身份，可过 Cloudflare）；失败时回退 URLSession
    func loadHTML(_ url: URL, readySelector: String?, completion: @escaping (Result<String, Error>) -> Void) {
        HTMLFetcher.shared.fetch(url, readySelector: readySelector) { [weak self] result in
            DispatchQueue.main.async { self?.lastDiagnostics = HTMLFetcher.shared.lastDiagnostics }
            switch result {
            case .success(let html) where html.count > 200:
                completion(.success(html))
            case .success, .failure:
                // 兜底：直接网络请求（部分网络下原生请求也能通）
                self?.getHTML(url) { fallback in
                    switch fallback {
                    case .success(let html) where !html.isEmpty:
                        completion(.success(html))
                    case .success:
                        completion(.failure(SiteDataError.empty))
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            }
        }
    }

    func getHTML(_ url: URL, referer: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let task = session.dataTask(with: makeRequest(url, referer: referer)) { data, response, error in
            if let error = error as NSError?, error.code == NSURLErrorTimedOut {
                completion(.failure(SiteDataError.timeout)); return
            }
            guard let http = response as? HTTPURLResponse, let data = data,
                  (200..<400).contains(http.statusCode) else {
                completion(.failure(SiteDataError.badResponse)); return
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            if html.isEmpty {
                completion(.failure(SiteDataError.badResponse)); return
            }
            completion(.success(html))
        }
        task.resume()
    }

    // MARK: 列表页
    func fetchList(_ url: URL, completion: @escaping (Result<[VideoItem], Error>) -> Void) {
        loadHTML(url, readySelector: Self.listReadySelector) { result in
            switch result {
            case .success(let html):
                let items = Self.parseCards(html)
                if items.isEmpty {
                    completion(.failure(SiteDataError.empty))
                } else {
                    completion(.success(items))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: 详情页
    func fetchDetail(_ url: URL, completion: @escaping (Result<VideoDetail, Error>) -> Void) {
        loadHTML(url, readySelector: Self.detailReadySelector) { result in
            switch result {
            case .success(let html):
                if let detail = Self.parseDetail(html, pageURL: url.absoluteString) {
                    completion(.success(detail))
                } else {
                    completion(.failure(SiteDataError.badResponse))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: 登录状态检测（未登录时底部"我的 Hanime1"链接指向 /login）
    func checkLoginState(completion: @escaping (Bool) -> Void) {
        loadHTML(URL(string: Self.base + "/")!, readySelector: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .success(let html) = result {
                    let mineHref = Self.match(pattern: #"<a href="([^"]+)"[^>]*>\s*<img[^>]*>\s*<div[^>]*>\s*我的"#, in: html).first
                    let loggedIn = !(mineHref?.contains("login") ?? true)
                    self.isLoggedIn = loggedIn
                    completion(loggedIn)
                } else {
                    completion(self.isLoggedIn)
                }
            }
        }
    }

    // MARK: 原生登录（在抓取引擎内以真实浏览器方式提交表单，Cookie 自动持久化）
    func login(email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        HTMLFetcher.shared.login(email: email, password: password) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                DispatchQueue.main.async { completion(.failure(err)) }
            case .success:
                self.checkLoginState { loggedIn in
                    DispatchQueue.main.async {
                        if loggedIn {
                            completion(.success(()))
                        } else {
                            completion(.failure(SiteDataError.loginFailed("登录未生效，请重试")))
                        }
                    }
                }
            }
        }
    }

    func logout() {
        HTMLFetcher.shared.clearCookies()
        DispatchQueue.main.async { self.isLoggedIn = false }
    }

    // MARK: - HTML 解析

    /// 卡片结构（已验证）：
    /// <div title="标题" class="video-item-container">
    ///   <a href="https://hanime1.me/watch?v=NNN" class="video-link">
    ///     <img class="main-thumb" src="封面">
    ///     <div class="duration">..</div>
    ///   <div class="title">标题</div> <div class="subtitle">..</div>
    /// 非视频卡（赞助商广告）链接不含 watch?v=，直接过滤
    static func parseCards(_ html: String) -> [VideoItem] {
        let primary = parseCardsByContainer(html)
        if !primary.isEmpty { return primary }
        // 结构变化兜底：按 watch 链接锚点扫描
        return parseCardsByAnchors(html)
    }

    /// 解析器 A：按卡片容器切块（标准结构）
    static func parseCardsByContainer(_ html: String) -> [VideoItem] {
        var items: [VideoItem] = []
        var seen = Set<String>()

        guard let containerRegex = try? NSRegularExpression(pattern: #"<div[^>]*class="video-item-container""#) else { return [] }
        let full = html as NSString
        let matches = containerRegex.matches(in: html, range: NSRange(location: 0, length: full.length))
        guard matches.count > 0 else { return [] }

        for (i, m) in matches.enumerated() {
            // 容器开标签（含 title 属性）
            let openTag = full.substring(with: m.range)
            let containerTitle = match(pattern: #"title="([^"]*)""#, in: openTag).first ?? ""

            // 卡片主体：从开标签结束到下一个容器开始
            let chunkStart = NSMaxRange(m.range)
            let chunkEnd = i + 1 < matches.count ? matches[i + 1].range.location : full.length
            guard chunkStart < chunkEnd else { continue }
            let chunk = full.substring(with: NSRange(location: chunkStart, length: chunkEnd - chunkStart))

            // 只要站内视频链接（过滤赞助商广告卡）
            guard let href = match(pattern: #"href="https://hanime1\.me/watch\?v=\d+""#, in: chunk).first else { continue }
            let url = href.replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "")
            guard !seen.contains(url) else { continue }

            let cover = match(pattern: #"<img[^>]*class="main-thumb"[^>]*src="([^"]+)""#, in: chunk).first
                ?? match(pattern: #"<img[^>]*src="([^"]+)""#, in: chunk).first ?? ""
            let divTitle = match(pattern: #"<div class="title">\s*(.*?)\s*</div>"#, in: chunk).first ?? ""
            let rawTitle = containerTitle.isEmpty ? divTitle : containerTitle
            let title = decodeEntities(rawTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 2 else { continue }

            seen.insert(url)
            items.append(VideoItem(title: String(title.prefix(120)), cover: cover, url: url))
        }
        return items
    }

    /// 解析器 B：以 watch 链接为锚点，向前后各扩一段窗口找标题/封面
    static func parseCardsByAnchors(_ html: String) -> [VideoItem] {
        var items: [VideoItem] = []
        var seen = Set<String>()
        let ns = html as NSString

        for groups in matchGroups(pattern: #"<a[^>]+href="(https://hanime1\.me/watch\?v=\d+)""#, in: html) {
            guard let url = groups.first, !seen.contains(url) else { continue }
            guard let anchorRange = html.range(of: url) else { continue }
            let loc = html.distance(from: html.startIndex, to: anchorRange.lowerBound)
            let start = max(0, loc - 900)
            let end = min(ns.length, loc + 4500)
            guard start < end else { continue }
            let window = ns.substring(with: NSRange(location: start, length: end - start))

            let cover = match(pattern: #"<img[^>]*(?:data-src|src)="(https://vdownload\.hembed\.com/[^"]+)""#, in: window).first
                ?? match(pattern: #"<img[^>]*src="([^"]+)""#, in: window).first ?? ""
            let rawTitle = match(pattern: #"<div[^>]*title="([^"]+)""#, in: window).first
                ?? match(pattern: #"<div class="title">\s*(.*?)\s*</div>"#, in: window).first ?? ""
            let title = decodeEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 2 else { continue }

            seen.insert(url)
            items.append(VideoItem(title: String(title.prefix(120)), cover: cover, url: url))
        }
        return items
    }

    /// 详情页解析：og:title / description / poster / <source src size> 直链
    static func parseDetail(_ html: String, pageURL: String) -> VideoDetail? {
        let ogTitle = match(pattern: #"property="og:title" content="([^"]*)""#, in: html).first
            ?? match(pattern: #"<title>(.*?)</title>"#, in: html).first ?? ""
        var title = decodeEntities(ogTitle)
        for suffix in [" - Hanime1.me", "｜Hanime1.me", "&nbsp;-&nbsp;H動漫/裏番/線上看&nbsp;-&nbsp;Hanime1.me"] {
            title = title.replacingOccurrences(of: suffix, with: "")
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let desc = decodeEntities(match(pattern: #"name="description" content="([^"]*)""#, in: html).first ?? "")
        let cover = match(pattern: #"<video[^>]*poster="([^"]+)""#, in: html).first
            ?? match(pattern: #"property="og:image" content="([^"]*)""#, in: html).first ?? ""

        // 播放地址：详情页 HTML 里的 <video><source src="...mp4" size="720"> 直链
        var sources: [VideoSource] = []
        for groups in matchGroups(pattern: #"<source src="([^"]+)"\s+type="video/mp4"\s+size="(\d+)""#, in: html)
        where groups.count >= 2 {
            if !groups[0].isEmpty {
                sources.append(VideoSource(label: "\(groups[1])P", url: groups[0]))
            }
        }
        // 兜底：不带 size 的 mp4 source
        if sources.isEmpty {
            let plain = match(pattern: #"<source src="([^"]+\.(?:mp4|m3u8)[^"]*)""#, in: html)
            for src in plain {
                sources.append(VideoSource(label: src.contains("m3u8") ? "自动画质" : "默认画质", url: src))
            }
        }
        // 再兜底：全文任意媒体直链
        if sources.isEmpty {
            let loose = match(pattern: #"https?://[^"'<>\s]+?\.(?:m3u8|mp4)(?:\?[^"'<>\s]*)?"#, in: html)
            var seenLoose = Set<String>()
            for src in loose where seenLoose.insert(src).inserted {
                sources.append(VideoSource(label: "视频源 \(sources.count + 1)", url: src))
                if sources.count >= 4 { break }
            }
        }
        guard !sources.isEmpty else { return nil }

        // 去重（同一地址不同画质不算重复）
        var uniqueSources: [VideoSource] = []
        var seenURL = Set<String>()
        for s in sources where seenURL.insert(s.url).inserted { uniqueSources.append(s) }

        return VideoDetail(title: title, cover: cover, desc: desc,
                           tags: [], sources: uniqueSources, watchURL: pageURL)
    }

    // MARK: 工具
    static func match(pattern: String, in text: String) -> [String] {
        matchGroups(pattern: pattern, in: text).compactMap { $0.first }
    }

    /// 返回每个匹配的所有捕获组
    static func matchGroups(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { m in (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) } }
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#039;", "'"),
            ("&hellip;", "…"), ("&mdash;", "—"), ("&middot;", "·")
        ]
        for (entity, char) in named {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // 数字实体 &#123;
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = out as NSString
            let replacements = regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).compactMap { m -> (NSRange, String)? in
                guard m.numberOfRanges > 1,
                      let code = UInt32(ns.substring(with: m.range(at: 1))),
                      let scalar = Unicode.Scalar(code) else { return nil }
                return (m.range, String(Character(scalar)))
            }
            for (range, str) in replacements.reversed() {
                out = (out as NSString).replacingCharacters(in: range, with: str)
            }
        }
        return out
    }
}
