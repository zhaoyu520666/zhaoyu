import SwiftUI
import WebKit

// MARK: - 主界面（原生 App 外壳：底部导航 + 原生页面）
struct ContentView: View {
    @StateObject private var store = SiteDataStore.shared
    @StateObject private var downloads = DownloadManager.shared

    @State private var tab = 0
    @State private var showDownloads = false
    @State private var showLogin = false

    private let tabTitles = ["主页", "本日排行", "订阅内容", "我的"]
    private let tabIcons = ["house.fill", "rectangle.stack.fill", "play.rectangle.fill", "person.crop.square.fill"]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TabHeader(
                    title: tabTitles[tab],
                    icon: tabIcons[tab],
                    onReload: {
                        store.clearCache()
                    },
                    extraIcon: "arrow.down.circle",
                    onExtra: { showDownloads = true }
                )

                Group {
                    switch tab {
                    case 0:
                        VideoGridView(baseURL: store.homeURL, allowSearch: true)
                    case 1:
                        VideoGridView(baseURL: store.rankURL)
                    case 2:
                        VideoGridView(
                            baseURL: store.subsURL,
                            emptyHint: "订阅内容需要先登录（到「我的」→ 登录后重试）"
                        )
                    default:
                        MineView(
                            onLogin: { showLogin = true },
                            onDownloads: { showDownloads = true }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                BottomNavBar(selected: $tab, titles: tabTitles, icons: tabIcons)
            }
            .background(Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
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
        .fullScreenCover(isPresented: $showLogin) {
            WebSheetView(url: store.homeURL)
        }
        .onAppear {
            store.activate()   // 启动数据引擎（隐藏 WebView 抓取导航地址）
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

// MARK: - 底部导航栏（主页 / 本日排行 / 订阅内容 / 我的）
struct BottomNavBar: View {
    @Binding var selected: Int
    var titles: [String]
    var icons: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { pair in
                Button {
                    selected = pair.offset
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icons[pair.offset])
                            .font(.system(size: 19, weight: .medium))
                        Text(titles[pair.offset])
                            .font(.system(size: 10))
                    }
                    .foregroundColor(selected == pair.offset ? .white : Color(white: 0.55))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 54)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14).ignoresSafeArea(edges: .bottom))
    }
}
