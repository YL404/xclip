import Foundation

/// XClipCore 出站 HTTP 请求的统一入口：环境变量代理 + 瞬时网络错误重试。
/// URLSession 默认只读系统代理（scutil --proxy），不读 HTTPS_PROXY 环境变量——
/// 终端/Agent 环境常配 `HTTPS_PROXY=http://127.0.0.1:7897`，靠这里显式接上。
enum HTTPClient {
    /// 从 HTTPS_PROXY/https_proxy/HTTP_PROXY/http_proxy/ALL_PROXY/all_proxy 中
    /// 解析第一个能用的代理，返回配置了 connectionProxyDictionary 的 URLSession；
    /// 没配置或解析不出 host/port 时返回 nil（调用方走直连）。
    static func environmentProxySession(
        configure: (URLSessionConfiguration) -> Void = { _ in }
    ) -> URLSession? {
        guard let dictionary = environmentProxyDictionary() else { return nil }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = dictionary
        configure(configuration)
        return URLSession(configuration: configuration)
    }

    /// 发起请求：file:// 等本地地址不掺代理与重试，直接请求。
    /// 远程 http(s)：无代理时直连最多 3 次（间隔 200ms、500ms）；代理活着时走
    /// 代理→代理→直连→代理 共 4 次（间隔 200/400/600ms）——并发抖动 200ms 重试
    /// 多半即成，不急着切必卡 15s 请求超时的直连。代理本身连不上时立即回退直连。
    /// 408/429/5xx 响应视同瞬时错误重试。
    static func data(from url: URL, session: URLSession,
                     proxySession: URLSession? = nil) async throws -> (Data, URLResponse) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return try await session.data(from: url)
        }
        var proxyAlive = proxySession != nil
        let attemptCount = proxyAlive ? 4 : 3
        let delays: [UInt64] = proxyAlive
            ? [200_000_000, 400_000_000, 600_000_000]
            : [200_000_000, 500_000_000]
        var immediate = false
        var lastError: Error?
        var lastResponse: (Data, URLResponse)?
        for attempt in 0..<attemptCount {
            if attempt > 0 {
                if !immediate {
                    try await Task.sleep(nanoseconds: delays[attempt - 1])
                }
                immediate = false
            }
            // 代理活着时的通道顺序：0、1 走代理，2 直连兜底，3 再试代理
            let useProxy = proxyAlive && attempt != 2
            do {
                let result = try await (useProxy ? proxySession! : session).data(from: url)
                if let http = result.1 as? HTTPURLResponse, isTransientStatus(http.statusCode) {
                    lastResponse = result
                    lastError = nil
                    continue
                }
                return result
            } catch let error as URLError {
                lastError = error
                lastResponse = nil
                // 连不上代理本身（代理进程没起）：立即无缝回退直连，且不再用它
                if useProxy, error.code == .cannotConnectToHost {
                    proxyAlive = false
                    immediate = true
                    continue
                }
                guard isTransient(error) else { throw error }
            }
        }
        // 重试耗尽：有最后一次响应就返回给调用方按其状态码语义处理，否则抛最后的错误
        if let lastResponse { return lastResponse }
        throw lastError ?? URLError(.unknown)
    }

    /// 瞬时 HTTP 状态码：代理上游抖动或限流的正常响应——408/429/5xx 值得重试，
    /// 其余（含 4xx）重试也不会变，原样交回调用方判断。
    static func isTransientStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500..<600).contains(code)
    }

    /// 瞬时网络错误：TLS 握手被重置（-1200）、连接中断、超时、连不上/找不到主机、
    /// DNS 失败——重试有机会成功；其余错误（如取消、badURL）重试也没意义。
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    static func environmentProxyDictionary() -> [String: Any]? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            // "127.0.0.1:7897" 这类不带 scheme 的写法补一个再解析
            let candidate = raw.contains("://") ? raw : "http://\(raw)"
            guard let url = URL(string: candidate),
                  let host = url.host, !host.isEmpty, let port = url.port else { continue }
            let scheme = url.scheme?.lowercased() ?? "http"
            if scheme == "socks5" || scheme == "socks5h" || scheme == "socks" {
                return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
            }
            return [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port
            ]
        }
        return nil
    }
}
