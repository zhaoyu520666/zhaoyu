import SwiftUI
import AVKit

// MARK: - 下载条目
struct DownloadItem: Identifiable {
    enum State { case downloading, completed, failed }
    let id = UUID()
    var fileName: String
    var remoteURL: URL
    var state: State = .downloading
    var progress: Double = 0
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var localURL: URL?
}

func formattedSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - 下载管理器
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    @Published var items: [DownloadItem] = []
    @Published var toast: String?

    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var toastWork: DispatchWorkItem?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var downloadsDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init() {
        super.init()
        reloadFromDisk()
    }

    /// 启动时扫描沙盒里已下载完成的文件
    func reloadFromDisk() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDir, includingPropertiesForKeys: nil)) ?? []
        let loaded = files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map {
                DownloadItem(fileName: $0.lastPathComponent, remoteURL: $0,
                             state: .completed, progress: 1,
                             receivedBytes: 0, totalBytes: 0, localURL: $0)
            }
        let inFlight = items.filter { $0.state == .downloading }
        items = loaded + inFlight
    }

    /// 判断是不是视频直链（点击时直接转交下载）
    static func isDirectMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "webm", "mov", "m4v", "mkv", "avi", "ts"].contains(ext)
    }

    /// 开始下载
    /// - Parameter title: 视频标题，用来给文件命名
    func startDownload(from url: URL, title: String? = nil) {
        let fileName = makeFileName(title: title, url: url)
        beginDownload(from: url, fileName: fileName)
    }

    private func beginDownload(from url: URL, fileName: String) {
        if items.contains(where: { $0.remoteURL == url && $0.state == .downloading }) {
            showToast("该视频已在下载队列中")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("https://hanime1.me/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.taskDescription = fileName   // 下载完成后用这个名字落盘（跨线程安全）
        let item = DownloadItem(fileName: fileName, remoteURL: url)
        tasks[item.id] = task
        items.insert(item, at: 0)
        task.resume()
        showToast("已开始下载：\(fileName)")
    }

    // MARK: 文件名
    /// 优先用视频标题命名：清理站名后缀、非法字符，补上扩展名
    private func makeFileName(title: String?, url: URL) -> String {
        var base = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉 "- Hanime1.me" / "| Hanime1.me" 之类的站点后缀
        for separator in [" - ", " | ", " – ", " — ", "｜"] {
            let parts = base.components(separatedBy: separator)
            if parts.count > 1, parts.last!.lowercased().contains("hanime") {
                base = parts.dropLast().joined(separator: separator)
            }
        }
        base = base.replacingOccurrences(of: "Hanime1.me", with: "", options: .caseInsensitive)
        base = base.replacingOccurrences(of: "Hanime1", with: "", options: .caseInsensitive)
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: " -|｜_."))

        // 标题太长时截断，避免文件名过长
        if base.count > 80 {
            base = String(base.prefix(80))
        }
        if base.isEmpty {
            base = url.deletingPathExtension().lastPathComponent
        }
        base = sanitize(base)

        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 {
            ext = "mp4"
        }
        return "\(base).\(ext)"
    }

    /// 取消进行中的下载 / 删除已完成文件
    func cancelOrDelete(_ item: DownloadItem) {
        if let task = tasks[item.id] {
            task.cancel() // 回调里会自动移除条目
            return
        }
        if let local = item.localURL {
            try? FileManager.default.removeItem(at: local)
        }
        items.removeAll { $0.id == item.id }
    }

    // MARK: Toast
    private func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { self.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: 文件名处理
    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "video" : cleaned
    }

    private func uniqueDestination(_ name: String) -> URL {
        var dest = downloadsDir.appendingPathComponent(name)
        var n = 1
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloadsDir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return dest
    }

    private func entry(for task: URLSessionDownloadTask) -> (Int, UUID)? {
        for (id, t) in tasks where t === task {
            if let idx = items.firstIndex(where: { $0.id == id }) { return (idx, id) }
        }
        return nil
    }

    // MARK: URLSessionDownloadDelegate（全部回主线程再改状态）
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            guard let (index, id) = self.entry(for: downloadTask),
                  self.items.indices.contains(index), self.items[index].id == id else { return }
            self.items[index].receivedBytes = totalBytesWritten
            self.items[index].totalBytes = totalBytesExpectedToWrite
            self.items[index].progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 优先用「视频标题」命名的名字（startDownload 时写进 taskDescription）
        var name = downloadTask.taskDescription
            ?? downloadTask.response?.suggestedFilename
            ?? downloadTask.originalRequest?.url?.lastPathComponent
            ?? "video.mp4"
        name = sanitize(name)

        if (name as NSString).pathExtension.isEmpty {
            let ext = ((downloadTask.response?.suggestedFilename ?? "") as NSString).pathExtension
            name += "." + (ext.isEmpty ? "mp4" : ext.lowercased())
        }

        let dest = uniqueDestination(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            try? FileManager.default.copyItem(at: location, to: dest)
            try? FileManager.default.removeItem(at: location)
        }
        let finalName = dest.lastPathComponent
        DispatchQueue.main.async {
            guard let (index, id) = self.entry(for: downloadTask) else { return }
            self.items[index].state = .completed
            self.items[index].progress = 1
            self.items[index].fileName = finalName
            self.items[index].localURL = dest
            self.tasks[id] = nil
            self.showToast("下载完成：\(finalName)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return } // 无 error = 正常完成，走 didFinish
        let downloadTask = task as? URLSessionDownloadTask
        DispatchQueue.main.async {
            guard let dt = downloadTask, let (index, id) = self.entry(for: dt) else { return }
            if (error as NSError).code == NSURLErrorCancelled {
                self.items.remove(at: index)
            } else {
                self.items[index].state = .failed
                self.showToast("下载失败：\((error as NSError).localizedDescription)")
            }
            self.tasks[id] = nil
        }
    }
}

// MARK: - 下载列表页
struct DownloadsTabView: View {
    var onClose: (() -> Void)? = nil

    @StateObject private var manager = DownloadManager.shared
    @State private var playingItem: DownloadItem?

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(
                title: "下载",
                icon: "arrow.down.circle",
                extraIcon: onClose == nil ? nil : "xmark",
                onExtra: onClose
            )

            Group {
                if manager.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 44))
                            .foregroundColor(.gray)
                        Text("还没有下载内容")
                            .foregroundColor(.gray)
                        Text("在网页里点视频的下载链接，会自动加到这里")
                            .font(.footnote)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if item.state == .completed { playingItem = item }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        manager.cancelOrDelete(item)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
        .fullScreenCover(item: $playingItem) { item in
            PlayerView(item: item)
        }
    }
}

// MARK: - 下载列表行
struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.state == .failed ? "exclamationmark.triangle.fill" : "video.fill")
                .foregroundColor(item.state == .failed ? .red : .pink)
                .font(.system(size: 22))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.fileName)
                    .font(.footnote)
                    .lineLimit(2)

                switch item.state {
                case .downloading:
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(.pink)
                    HStack {
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Spacer()
                        if item.totalBytes > 0 {
                            Text("\(formattedSize(item.receivedBytes)) / \(formattedSize(item.totalBytes))")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                case .completed:
                    Text("已完成 · 点按播放")
                        .font(.caption2)
                        .foregroundColor(.green)
                case .failed:
                    Text("下载失败 · 左滑删除后可重试")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 本地播放器
struct PlayerView: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(14)
        }
        .onAppear {
            if let url = item.localURL {
                player = AVPlayer(url: url)
                player?.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
