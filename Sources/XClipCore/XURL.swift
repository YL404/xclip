import Foundation

public enum XURLError: Error, Equatable {
    case notAnXURL
    case missingStatusID
}

public struct PostRef: Equatable, Sendable {
    public let screenName: String   // `/i/status/<id>` 形式下为空
    public let id: String
    public let url: String          // canonical: https://x.com/<handle>/status/<id>

    public init(screenName: String, id: String, url: String) {
        self.screenName = screenName
        self.id = id
        self.url = url
    }
}

public enum XURL {
    private static let allowedHosts: Set<String> = [
        "x.com", "twitter.com", "www.x.com", "www.twitter.com", "mobile.x.com", "mobile.twitter.com"
    ]

    /// 把各种形态的 X 链接收敛为 canonical URL。v1 只接受 X，其他域名抛错。
    public static func canonicalPostURL(_ raw: String) throws -> PostRef {
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { throw XURLError.notAnXURL }
        if !string.contains("://") { string = "https://" + string }

        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host)
        else { throw XURLError.notAnXURL }

        // <handle>/status/<id>[/photo/1 ...] 或 i/status/<id>[/...]
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "status" else { throw XURLError.notAnXURL }
        let id = parts[2]
        guard !id.isEmpty, id.allSatisfy({ $0.isNumber }) else { throw XURLError.missingStatusID }

        if parts[0] == "i" {
            return PostRef(screenName: "", id: id, url: "https://x.com/i/status/\(id)")
        }
        let handle = parts[0].lowercased()
        return PostRef(screenName: handle, id: id, url: "https://x.com/\(handle)/status/\(id)")
    }
}
