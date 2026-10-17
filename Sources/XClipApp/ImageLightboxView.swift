import AppKit
import SwiftUI
import XClipCore

/// 全窗口大图查看器：详情页里点图片后由 ContentView 在最顶层渲染，
/// 不受详情卡片宽度限制，直接铺满应用窗口。
///
/// 交互：−/百分比/+ 按钮（最大 3x）、双击 1x↔2x、双指捏合缩放、放大后拖拽平移；
/// 多图左右按钮和 ←/→ 键切换；点遮罩、点 ✕、按 Esc 关闭（Esc 只关本层，
/// 详情页的关闭快捷键在查看器打开期间被挂起）。
struct ImageLightboxView: View {
    let images: [MediaItem]
    @Binding var index: Int
    let store: LibraryStore
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var current: MediaItem { images[index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            imageView
                .padding(24)

            if images.count > 1 {
                HStack {
                    navButton("chevron.left", key: .leftArrow) { move(-1) }
                    Spacer()
                    navButton("chevron.right", key: .rightArrow) { move(1) }
                }
                .padding(.horizontal, 14)
            }

            VStack {
                HStack {
                    Spacer()
                    closeButton
                }
                Spacer()
                toolbar
            }
            .padding(16)
        }
        // 图换了重置缩放和平移
        .onChange(of: index) { _, _ in resetTransform() }
    }

    // MARK: - 图片区

    private var imageView: some View {
        AsyncImage(url: store.resolveMediaURL(current.url, variant: .large)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                Label("图片加载失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .scaleEffect(scale)
        .offset(offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // 双击切换 1x/2x；单击落在图区不穿透到遮罩（不关闭）
        .onTapGesture(count: 2) { toggleZoom() }
        .onTapGesture(count: 1) {}
        .gesture(magnify)
        .simultaneousGesture(pan)
        .animation(.easeOut(duration: 0.15), value: scale)
        .animation(.easeOut(duration: 0.15), value: offset)
    }

    // MARK: - 控件

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("关闭 (Esc)")
        .accessibilityLabel("关闭大图查看")
    }

    private func navButton(_ systemImage: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { setScale(scale - 0.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("缩小")
            Button { resetTransform() } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .help("还原为 100%")
            Button { setScale(scale + 0.5) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("放大")
            if images.count > 1 {
                Divider().frame(height: 14)
                Text("\(index + 1) / \(images.count)")
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: - 手势与变换

    /// 双指捏合缩放（触控板 pinch）。
    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                setScale(lastScale * value.magnification)
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    /// 放大后按住拖拽平移。
    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func setScale(_ value: CGFloat) {
        scale = min(max(value, 1), 3)
        if scale == 1 {
            offset = .zero
            lastOffset = .zero
        }
    }

    private func resetTransform() {
        setScale(1)
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func toggleZoom() {
        setScale(scale > 1 ? 1 : 2)
        lastScale = scale
    }

    private func move(_ delta: Int) {
        index = (index + delta + images.count) % images.count
    }
}
