import AppKit
import SwiftUI
import TimelineCore

/// 缩略图方块；文件缺失时显示占位。
struct ImageThumb: View {
    let url: URL
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let image = ImageTools.thumbnail(url, maxPixel: Int(size * 3)) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: size * 0.35)).foregroundStyle(TerminalPalette.muted)
            }
        }
        .frame(width: size, height: size)
        .background(Palette.line.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
    }
}

/// 完整显示一张图：按原始比例缩小到放得进框里，不裁剪。截取的论文插图通常不大，缩小后可以整张看清。
struct ImageFit: View {
    let url: URL
    var maxWidth: CGFloat = 320
    var maxHeight: CGFloat = 170

    var body: some View {
        if let image = ImageTools.thumbnail(url, maxPixel: Int(max(maxWidth, maxHeight) * 3)) {
            let size = ImageTools.fittedSize(pixels: image.size, maxWidth: maxWidth, maxHeight: maxHeight)
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
        } else {
            ImageThumb(url: url, size: 56)
        }
    }
}

/// 输入框上方：已粘贴、还没提交的图片。
struct PendingImagesStrip: View {
    @Environment(\.typography) private var typography
    let store: JournalStore
    let names: [String]
    let remove: (String) -> Void
    let preview: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    Button { preview(index) } label: { ImageThumb(url: store.imageURL(name)) }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(name) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                    .foregroundStyle(Color.white, Color.black.opacity(0.7))
                            }
                            .buttonStyle(.plain).offset(x: 5, y: -5)
                            .help("移除这张图片").accessibilityLabel("移除图片")
                        }
                        .help("点击查看大图")
                        .accessibilityLabel("待发送图片 \(index + 1)")
                }
                Text("\(names.count) 张图片，回车随日志一起保存")
                    .font(.system(size: typography.pt(11))).foregroundStyle(TerminalPalette.muted)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }
}

/// 日志行展开后显示的缩略图。
struct LogImageGallery: View {
    let store: JournalStore
    let names: [String]
    let preview: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    Button { preview(index) } label: { ImageFit(url: store.imageURL(name), maxWidth: 360, maxHeight: 190) }
                        .buttonStyle(.plain)
                        .help("点击查看大图").accessibilityLabel("图片 \(index + 1) / \(names.count)，查看大图")
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.leading, 76)
    }
}

/// 大图预览：← → 切换，Esc 关闭，可在「预览」中打开或复制。
/// 选择要筛选的任务：当天清单里的任务，以及所有被日志关联过的任务。
struct LogFilterPopover: View {
    @ObservedObject var store: JournalStore
    let date: Date
    @Binding var selection: Set<UUID>

    var body: some View {
        let summaries = store.logTaskSummaries(on: date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("按任务筛选日志").font(.headline)
                Spacer()
                Button("清除") { selection = [] }.disabled(selection.isEmpty)
            }
            Text("勾选任务以筛选日志")
                .font(.caption).foregroundStyle(Palette.muted)
            if summaries.isEmpty {
                Text("还没有待办").font(.callout).foregroundStyle(Palette.muted).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summaries) { task in
                            Toggle(isOn: Binding(get: { selection.contains(task.id) },
                                                 set: { if $0 { selection.insert(task.id) } else { selection.remove(task.id) } })) {
                                HStack(spacing: 6) {
                                    if let number = task.number {
                                        Text("#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                                    }
                                    Text(task.title).lineLimit(1)
                                    if task.deleted { Text("（已删除）").font(.caption).foregroundStyle(Palette.muted) }
                                    Spacer(minLength: 8)
                                    Text("\(task.count) 条").font(.caption).foregroundStyle(Palette.muted)
                                }
                            }
                            .toggleStyle(.checkbox).padding(.vertical, 3)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }
        .padding(16).frame(width: 340)
    }
}
