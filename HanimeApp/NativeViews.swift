import SwiftUI
import AVKit
import WebKit

// MARK: - 视频网格（原生列表页：主页 / 本日排行 / 订阅内容 / 搜索结果）
struct VideoGridView: View {
    var baseURL: URL
    var allowSearch = false
    var emptyHint: String? = nil

    @ObservedObject private var store = SiteDataStore.shared
    @State private var activeURL: URL
    @State private var activeBase: URL
    @State private var items: [VideoItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var query = ""
    @State private var webFallback: URL?
    @State private var lastRev = -1

    init(baseURL: URL, allowSearch: Bool = false, emptyHint: String? = nil) {
        self.baseURL = baseURL
        self.allowSearch = allowSearch
        self.emptyHint = emptyHint
        _activeURL = State(initialValue: baseURL)
        _activeBase = State(initialValue: baseURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            if allowSearch {
                searchField
            }
            content
        }
        .onAppear { if items.isEmpty { load(reset: true) } }
        .onChange(of: baseURL) { newBase in
            // 启动早期导航地址还没解析时可能先用了回退地址，解析完成后自动切换重载
            let untouched = items.isEmpty || activeURL == activeBase
            activeBase = newBase
            guard untouched, newBase != activeURL else { return }
            activeURL = newBase
            page = 1
            items = []
            load(reset: true)
        }
        .onReceive(store.$revision) { rev in
            guard rev != lastRev else { return }
            lastRev = rev
            guard rev > 0 else { return }   // 首次订阅的初始值不算"刷新"
            activeURL = baseURL
            page = 1
            items = []
            load(reset: true)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
        .fullScreenCover(item: Binding(
            get: { webFallback.map { WebFallbackBox(url: $0) } },
            set: { webFallback = $0?.url }
        )) { box in
            WebSheetView(url: box.url)
        }
    }

    // 搜索框
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.gray)
            TextField("搜索影片…", text: $query, onCommit: submitSearch)
                .foregroundColor(.white)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !query.isEmpty {
                Button(action: { query = ""; resetToBase() }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.13))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // 主体
    @ViewBuilder private var content: some View {
        if loading && items.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(.pink)
                Text("正在加载…").font(.footnote).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorText, items.isEmpty {
            errorView(error)
        } else if items.isEmpty {
            emptyView
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 16) {
                    ForEach(items) { item in
                        VideoCardView(item: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                if loading {
                    ProgressView().tint(.pink).padding(.vertical, 14)
                } else if hasMore {
                    Button(action: { page += 1; load(reset: false) }) {
                        Text("加载更多")
                            .font(.footnote)
                            .foregroundColor(.pink)
                            .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 42))
                .foregroundColor(.gray)
            Text(emptyHint ?? "这里还没有内容")
                .font(.footnote)
                .foregroundColor(.gray)
            Button(action: { webFallback = activeURL }) {
                Label("打开网页版查看", systemImage: "safari")
                    .font(.footnote)
                    .foregroundColor(.pink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42))
                .foregroundColor(.gray)
            Text(message).font(.footnote).foregroundColor(.gray)
            Button(action: { load(reset: true) }) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.footnote).foregroundColor(.pink)
            }
            Button(action: { webFallback = activeURL }) {
                Label("用网页版打开", systemImage: "safari")
                    .font(.footnote).foregroundColor(.pink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 数据
    private func submitSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { resetToBase(); return }
        var comps = URLComponents(url: URL(string: "https://hanime1.me/search")!, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "v", value: ""), URLQueryItem(name: "query", value: q)]
        if let u = comps.url {
            activeURL = u
            items = []
            page = 1
            load(reset: true)
        }
    }

    private func resetToBase() {
        activeURL = baseURL
        items = []
        page = 1
        load(reset: true)
    }

    private func pageURL(_ n: Int) -> URL {
        guard n > 1, var comps = URLComponents(url: activeURL, resolvingAgainstBaseURL: false) else { return activeURL }
        var q = comps.queryItems ?? []
        q.removeAll { $0.name == "page" }
        q.append(URLQueryItem(name: "page", value: String(n)))
        comps.queryItems = q
        return comps.url ?? activeURL
    }

    private func load(reset: Bool) {
        let target = reset ? activeURL : pageURL(page)
        loading = true
        if reset { errorText = nil }
        store.fetchList(target) { result in
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let fetched):
                    let existing = Set(items.map { $0.url })
                    let fresh = fetched.filter { !existing.contains($0.url) }
                    if reset { items = fetched } else { items += fresh }
                    hasMore = !fetched.isEmpty && target.absoluteString.contains("search")
                    if fetched.isEmpty && reset { errorText = SiteDataError.empty.localizedDescription }
                case .failure(let err):
                    if reset { items = []; errorText = err.localizedDescription }
                }
            }
        }
    }
}

// fullScreenCover 的 item 包装
struct WebFallbackBox: Identifiable {
    let url: URL
    var id: URL { url }
}

// MARK: - 封面图加载（内存缓存 + 降采样解码，避免滚动卡顿）
final class ThumbCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct CachedCoverImage: View {
    let url: URL?
    var targetWidth: CGFloat = 400

    @State private var image: UIImage?
    @State private var failed = false
    @State private var task: URLSessionTask?

    var body: some View {
        ZStack {
            Color(white: 0.13)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo").foregroundColor(.gray)
            } else {
                ProgressView().tint(.pink)
            }
        }
        .onAppear { load() }
        .onDisappear { task?.cancel() }
    }

    private func load() {
        guard let url = url else { failed = true; return }
        let key = url.absoluteString as NSString
        if let hit = ThumbCache.shared.object(forKey: key) {
            image = hit
            failed = false
            return
        }
        let maxPixel = targetWidth * UIScreen.main.scale
        task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let thumb = Self.downsampled(data: data, maxPixel: maxPixel) else {
                DispatchQueue.main.async { failed = true }
                return
            }
            ThumbCache.shared.setObject(thumb, forKey: key)
            DispatchQueue.main.async { image = thumb; failed = false }
        }
        task?.resume()
    }

    /// 用 ImageIO 直接解码缩略图，不把整张原图读进内存
    private static func downsampled(data: Data, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 视频卡片
struct VideoCardView: View {
    let item: VideoItem

    var body: some View {
        NavigationLink(destination: VideoDetailView(item: item)) {
            VStack(alignment: .leading, spacing: 6) {
                CachedCoverImage(url: item.coverURL, targetWidth: 360)
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)

                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 详情页
struct VideoDetailView: View {
    let item: VideoItem

    @State private var detail: VideoDetail?
    @State private var loading = true
    @State private var errorText: String?
    @State private var playerBundle: PlayerBundle?
    @State private var webFallback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cover
                info
                actions
                if let d = detail, !d.desc.isEmpty {
                    Text(d.desc)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .lineLimit(6)
                }
                if let d = detail, !d.tags.isEmpty {
                    flowTags(d.tags)
                }
            }
            .padding(14)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarHidden(true)
        .onAppear { load() }
        .fullScreenCover(item: $playerBundle) { bundle in
            PlayerScreen(sources: bundle.sources)
        }
        .fullScreenCover(isPresented: $webFallback) {
            WebSheetView(url: item.pageURL ?? SiteDataStore.shared.homeURL)
        }
    }

    private var cover: some View {
        CachedCoverImage(url: item.coverURL, targetWidth: 800)
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()
            .cornerRadius(10)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail?.title.isEmpty == false ? detail!.title : item.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            if let d = detail, !d.tags.isEmpty {
                Text(d.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(.pink)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView().tint(.pink)
                Text("正在解析播放地址…").font(.footnote).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        } else if let d = detail {
            VStack(spacing: 10) {
                ForEach(d.sources) { source in
                    Button(action: { playerBundle = PlayerBundle(sources: d.sources, current: source) }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text(source.label)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 16)
                        .background(Color(red: 0.96, green: 0.44, blue: 0.55))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: { webFallback = true }) {
                    Label("网页方式播放（备用）", systemImage: "safari")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            VStack(spacing: 10) {
                Text(errorText ?? "解析失败")
                    .font(.footnote)
                    .foregroundColor(.gray)
                Button(action: load) {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.footnote).foregroundColor(.pink)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Button(action: { webFallback = true }) {
                    Label("用网页版打开", systemImage: "safari")
                        .font(.footnote).foregroundColor(.pink)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func flowTags(_ tags: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(white: 0.16))
                    .cornerRadius(14)
            }
        }
    }

    private func load() {
        guard let url = item.pageURL else { return }
        loading = true
        errorText = nil
        SiteDataStore.shared.fetchDetail(url) { result in
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let d): detail = d
                case .failure(let err): errorText = err.localizedDescription
                }
            }
        }
    }
}

struct PlayerBundle: Identifiable {
    let sources: [VideoSource]
    var current: VideoSource? = nil
    var id = UUID()
}

// MARK: - 原生播放器（AVPlayer，支持 HLS / 手势 / 画中画）
struct PlayerScreen: View {
    let sources: [VideoSource]

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(sources: [VideoSource], start: VideoSource? = nil) {
        self.sources = sources
        _index = State(initialValue: sources.firstIndex(where: { $0.id == start?.id }) ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }
                Spacer()
                if sources.count > 1 {
                    Menu {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { pair in
                            Button(pair.element.label) { index = pair.offset }
                        }
                    } label: {
                        Label(sources[index].label, systemImage: "slider.horizontal.3")
                            .font(.footnote)
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))

            NativePlayerAV(urlString: sources[index].url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .id(sources[index].url)

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

struct NativePlayerAV: UIViewControllerRepresentable {
    let urlString: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        if let url = URL(string: urlString) {
            let headers = [
                "Referer": "https://hanime1.me/",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
            ]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            vc.player = player
            vc.allowsPictureInPicturePlayback = true
            player.play()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 我的
struct MineView: View {
    var onLogin: () -> Void
    var onDownloads: () -> Void

    var body: some View {
        List {
            Section {
                Button(action: onLogin) {
                    Label("登录 / 我的账户", systemImage: "person.crop.circle")
                        .foregroundColor(.white)
                }
                Button(action: onDownloads) {
                    Label("下载管理", systemImage: "arrow.down.circle")
                        .foregroundColor(.white)
                }
            } header: {
                Text("账户").font(.footnote).foregroundColor(.gray)
            }

            Section {
                Button(action: onLogin) {
                    Label("追番列表（登录后同步）", systemImage: "heart")
                        .foregroundColor(.white)
                }
            } header: {
                Text("收藏").font(.footnote).foregroundColor(.gray)
            }

            Section {
                HStack {
                    Label("版本", systemImage: "info.circle")
                        .foregroundColor(.white)
                    Spacer()
                    Text("2.0 原生版").font(.footnote).foregroundColor(.gray)
                }
            } header: {
                Text("关于").font(.footnote).foregroundColor(.gray)
            }
        }
        .listStyle(.insetGrouped)
    }
}
