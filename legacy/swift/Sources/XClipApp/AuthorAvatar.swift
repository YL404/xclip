import SwiftUI
import XClipCore

/// 作者头像占位：有远端地址用 AsyncImage，否则用首字母。
struct AuthorAvatar: View {
    let post: Post
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let url = avatarURL {
                // 缩略图未命中/解码中时由底下的首字母兜底
                ThumbnailImage(url: url, maxPixelSize: Int(size * 2))
                    .scaledToFill()
                    .background { initials }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// 优先用本地缓存的头像文件，没有才走远端，避免打开详情时先闪占位字母。
    /// 命中结果走 LocalFileURLCache：缓存过的文件不再重复 SHA256 + stat。
    private var avatarURL: URL? {
        guard let remote = post.authorAvatar else { return nil }
        return LocalFileURLCache.shared.localFile(for: remote) ?? URL(string: remote)
    }

    private var initials: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
    }

    /// 名字和 handle 都空（抓取失败的贴文）时用 ? 占位，不留空白圈。
    private var initial: String {
        let source = post.authorName.isEmpty ? post.authorHandle : post.authorName
        return source.isEmpty ? "?" : String(source.prefix(1)).uppercased()
    }
}
