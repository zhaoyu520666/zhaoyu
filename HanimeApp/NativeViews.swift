import SwiftUI
import AVKit

// MARK: - 视频网格（原生列表页：主页 / 本日排行 / 订阅内容 / 搜索结果）
struct VideoGridView: View {
    var baseURL: URL
    var allowSearch = false
    var emptyHint: String? = nil
    var reloadToken: Int = 0

    @State private var activeURL: URL
    @State private var items: [VideoItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var query = ""

    init(baseURL: URL, allowSearch: Bool = false, emptyHint: String? = nil, reloadToken: Int = 0) {
        self.baseURL = baseURL
        self.allowSearch = allowSearch
        self.emptyHint = emptyHint
        self.reloadToken = reloadToken
        _activeURL = State(initialValue: baseURL)
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
            activeURL = newBase
            items = []
            page = 1
            load(reset: true)
        }
        .onChange(of: reloadToken) { _ in
            activeURL = baseURL
            items = []
            page = 1
            load(reset: true)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
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
            Button(action: { load(reset: true) }) {
                Label("重试", systemImage: "arrow.clockwise")
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 数据
    private func submitSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { resetToBase(); return }
        var comps = URLComponents(url: URL(string: SiteAPI.base + "/search")!, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "query", value: q)]
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
        SiteAPI.shared.fetchList(target) { result in
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

// MARK: - 详情页（原生：AVPlayer 直连 MP4，支持下载）
struct VideoDetailView: View {
    let item: VideoItem

    @Environment(\.dismiss) private var dismiss
    @State private var detail: VideoDetail?
    @State private var loading = true
    @State private var errorText: String?
    @State private var playerBundle: PlayerBundle?

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
                        .lineLimit(8)
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
        .overlay(alignment: .topLeading) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 14)
            .padding(.top, 8)
        }
        .onAppear { load() }
        .fullScreenCover(item: $playerBundle) { bundle in
            PlayerScreen(sources: bundle.sources)
        }
    }

    private var cover: some View {
        CachedCoverImage(url: detail?.cover.isEmpty == false ? URL(string: detail!.cover) : item.coverURL, targetWidth: 800)
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
                Text("正在加载播放地址…").font(.footnote).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        } else if let d = detail {
            VStack(spacing: 10) {
                ForEach(d.sources) { source in
                    Button(action: { playerBundle = PlayerBundle(sources: d.sources, current: source) }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("播放 \(source.label)")
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
                ForEach(d.sources) { source in
                    Button(action: {
                        DownloadManager.shared.startDownload(
                            from: URL(string: source.url) ?? URL(string: "https://hanime1.me")!,
                            title: d.title)
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("下载 \(source.label)")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 16)
                        .background(Color(white: 0.16))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
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
        SiteAPI.shared.fetchDetail(url) { result in
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

// MARK: - 原生播放器（AVPlayer 直连，支持画质切换 / 画中画）
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
                "User-Agent": SiteAPI.mobileUA
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

// MARK: - 我的（原生账户页 + 原生登录表单，全程不跳网页）
struct MineView: View {
    @ObservedObject private var api = SiteAPI.shared
    var onDownloads: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var loginError: String?
    @State private var showPassword = false

    var body: some View {
        List {
            Section {
                if api.checkingLogin {
                    HStack {
                        ProgressView().tint(.pink)
                        Text("正在检测登录状态…").font(.footnote).foregroundColor(.gray)
                    }
                } else if api.isLoggedIn {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.pink)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已登录").font(.headline).foregroundColor(.white)
                            Text("账号数据已同步").font(.footnote).foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 4)
                    Button(role: .destructive, action: { api.logout() }) {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    loginForm
                }
            } header: {
                Text("账户").font(.footnote).foregroundColor(.gray)
            }

            Section {
                Button(action: onDownloads) {
                    Label("下载管理", systemImage: "arrow.down.circle")
                        .foregroundColor(.white)
                }
            } header: {
                Text("内容").font(.footnote).foregroundColor(.gray)
            }

            Section {
                HStack {
                    Label("版本", systemImage: "info.circle")
                        .foregroundColor(.white)
                    Spacer()
                    Text("3.0 全原生版").font(.footnote).foregroundColor(.gray)
                }
            } header: {
                Text("关于").font(.footnote).foregroundColor(.gray)
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            api.checkingLogin = true
            api.checkLoginState { _ in
                DispatchQueue.main.async { api.checkingLogin = false }
            }
        }
    }

    // 原生登录表单
    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登录 Hanime1 账号")
                .font(.headline)
                .foregroundColor(.white)

            TextField("邮箱地址", text: $email)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.white)
                .padding(10)
                .background(Color(white: 0.14))
                .cornerRadius(8)

            HStack {
                Group {
                    if showPassword {
                        TextField("密码", text: $password)
                    } else {
                        SecureField("密码", text: $password)
                    }
                }
                .foregroundColor(.white)
                .autocapitalization(.none)
                .disableAutocorrection(true)

                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundColor(.gray)
                        .font(.system(size: 14))
                }
            }
            .padding(10)
            .background(Color(white: 0.14))
            .cornerRadius(8)

            if let err = loginError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            Button(action: doLogin) {
                HStack {
                    if loggingIn {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(loggingIn ? "正在登录…" : "登录")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(email.isEmpty || password.isEmpty ? Color(red: 0.96, green: 0.44, blue: 0.55).opacity(0.4) : Color(red: 0.96, green: 0.44, blue: 0.55))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(loggingIn || email.isEmpty || password.isEmpty)
        }
        .padding(.vertical, 6)
    }

    private func doLogin() {
        loggingIn = true
        loginError = nil
        SiteAPI.shared.login(email: email, password: password) { result in
            DispatchQueue.main.async {
                loggingIn = false
                switch result {
                case .success:
                    api.isLoggedIn = true
                    password = ""
                case .failure(let err):
                    loginError = err.localizedDescription
                }
            }
        }
    }
}
