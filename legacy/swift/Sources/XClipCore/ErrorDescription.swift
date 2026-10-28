import Foundation

/// 把 core 抛出的错误转成用户可读的中文。CLI 和 App 共用同一份映射，
/// 避免两边文案漂移，也避免把 `The operation couldn't be completed` 抛给用户。
public func describe(_ error: Error) -> String {
    switch error {
    case let error as FetchError:
        switch error {
        case .missingScreenName: return "链接不含用户名，请贴完整链接"
        case .httpStatus(let code): return "HTTP \(code)"
        case .apiError(let message): return message
        case .malformedResponse: return "响应解析失败"
        }
    case let error as XURLError:
        switch error {
        case .notAnXURL: return "不是 X 链接"
        case .missingStatusID: return "链接缺少帖子 ID"
        }
    case let error as TagStoreError:
        return error.description
    case let error as PostStoreError:
        return error.description
    case let error as SummaryValidationError:
        return error.description
    case let error as DatabaseError:
        return error.description
    case let error as URLError:
        // 断网、超时、连不上主机是这个 app 最常见的网络失败，别把英文系统文案抛给用户
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "没有网络连接"
        case .timedOut:
            return "请求超时"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "连不上服务器"
        case .cancelled:
            return "已取消"
        default:
            return "网络错误（\(error.code.rawValue)）"
        }
    default:
        return error.localizedDescription
    }
}
