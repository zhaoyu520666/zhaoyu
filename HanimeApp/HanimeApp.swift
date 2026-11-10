import SwiftUI

@main
struct HanimeApp: App {
    init() {
        // 加大磁盘缓存：封面图重复进入不再重新下载
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: "image-cache"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
