import Foundation

public enum Paths {
    /// CLI 与 App 共用的数据库位置：`--db` 参数 > `XCLIP_DB` 环境变量 > `~/.xclip/xclip.db`
    public static func databasePath(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        if let fromEnv = environment["XCLIP_DB"], !fromEnv.isEmpty {
            return URL(fileURLWithPath: (fromEnv as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xclip/xclip.db", isDirectory: false)
    }

    /// 图片缓存根目录，跟着数据库走：`--db` 换了位置，缓存也跟着换。
    public static func mediaRoot(explicit: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let database = databasePath(explicit: explicit, environment: environment)
        return database.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
    }
}
