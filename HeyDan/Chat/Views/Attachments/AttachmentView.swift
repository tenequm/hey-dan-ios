import SwiftUI
import HeyDanCore
import ImageIO
import UniformTypeIdentifiers
import QuickLook

struct AttachmentView: View {
    @Environment(\.theme) private var theme
    private let file: FileAttachment
    private let localURL: URL?
    private let download: (FileAttachment) async throws -> URL
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var loadedURL: URL?
    @State private var previewURL: URL?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var requested = false
    @State private var destination: Destination?
    @State private var sharing = false

    private enum Destination { case preview, share }

    init(file: FileAttachment, download: @escaping (FileAttachment) async throws -> URL = { file in
        try await ChatController.shared.download(file)
    }) {
        self.file = file
        self.download = download
        localURL = nil
    }

    init(attachment: StagedAttachment) {
        let type = UTType(mimeType: attachment.mimeType)
        let size = (try? attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        file = FileAttachment(id: attachment.fileURL.absoluteString, name: attachment.name,
                              mimeType: attachment.mimeType, size: Int64(size),
                              kind: type?.conforms(to: .image) == true ? .image : .file)
        localURL = attachment.fileURL
        download = { _ in attachment.fileURL }
    }

    private var imageHeight: CGFloat {
        guard let width = file.width, let height = file.height, width > 0, height > 0 else { return 160 }
        return min(280, max(80, 240 * CGFloat(height) / CGFloat(width)))
    }

    private var icon: String {
        let type = UTType(mimeType: file.mimeType)
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .text) == true { return "doc.text" }
        return "doc"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s1) {
            HStack(spacing: theme.space.s2) {
                Button { open(.preview) } label: {
                    if file.kind == .image {
                        Rectangle().fill(theme.color.surfaceSubtle)
                            .aspectRatio(localURL == nil ? 240 / imageHeight : 1, contentMode: .fit)
                            .overlay {
                                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                                else if failure == nil { ProgressView() }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: theme.radius.m))
                            .frame(width: localURL == nil ? nil : 56, height: localURL == nil ? nil : 56)
                            .frame(maxWidth: 240)
                            .accessibilityLabel(file.name)
                    } else {
                        HStack(spacing: theme.space.s3) {
                            Image(systemName: icon)
                                .foregroundStyle(theme.color.iconMuted)
                                .frame(width: theme.space.s10, height: theme.space.s10)
                                .background(theme.color.surfaceSubtle, in: RoundedRectangle(cornerRadius: theme.radius.s))
                            VStack(alignment: .leading, spacing: theme.space.s0_5) {
                                Text(file.name).textRole(theme.type.footnote, theme.weight.semibold).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
                            }
                        }
                        .padding(theme.space.s3)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AXID.attachmentOpen)
                if localURL == nil && file.kind != .image {
                    Spacer(minLength: 0)
                    Button("Share", systemImage: "square.and.arrow.up") { open(.share) }
                        .labelStyle(.iconOnly).foregroundStyle(theme.color.iconMuted)
                        .frame(minWidth: theme.control.touchTarget, minHeight: theme.control.touchTarget)
                }
            }
            .frame(maxWidth: file.kind == .image ? nil : 280, alignment: .leading)
            .foregroundStyle(theme.color.textPrimary)
            .background(file.kind == .image ? .clear : theme.color.surfaceCard, in: RoundedRectangle(cornerRadius: theme.radius.l))
            .overlay {
                if file.kind != .image {
                    RoundedRectangle(cornerRadius: theme.radius.l).strokeBorder(theme.color.border).allowsHitTesting(false)
                }
            }
            if requested && loadedURL == nil && failure == nil && file.kind != .image { ProgressView() }
            if let failure {
                Text(failure).textRole(theme.type.caption).foregroundStyle(theme.color.danger)
                Button("Retry") { attempt += 1 }.tint(theme.color.accentText)
            }
        }
        .contextMenu {
            if let loadedURL { ShareLink(item: loadedURL) }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $sharing) {
            if let loadedURL { ActivitySheet(item: loadedURL).presentationDetents([.medium, .large]) }
        }
        .task(id: "\(file.id):\(attempt):\(displayScale)") {
            guard file.kind == .image || localURL != nil || requested else { return }
            failure = nil
            loadedURL = nil
            thumbnail = nil
            do {
                let url: URL
                if let localURL { url = localURL } else { url = try await download(file) }
                try Task.checkCancellation()
                if file.kind == .image {
                    let pixels = Int(max(240, imageHeight) * displayScale)
                    thumbnail = try await AttachmentThumbnails.shared.image(url: url, id: file.id, pixels: pixels)
                }
                try Task.checkCancellation()
                loadedURL = url
                if let destination { present(destination, url: url); self.destination = nil }
            } catch {
                guard !Task.isCancelled else { return }
                if case let AppError.server(_, body) = error {
                    failure = body.message
                } else {
                    failure = "Could not load the attachment. Check your connection and try again."
                }
            }
        }
    }
    private func open(_ target: Destination) {
        if let loadedURL { present(target, url: loadedURL) }
        else {
            destination = target
            if !requested || failure != nil { requested = true; attempt += 1 }
        }
    }

    private func present(_ target: Destination, url: URL) {
        switch target {
        case .preview: previewURL = url
        case .share: sharing = true
        }
    }
}

struct ActivitySheet<Item>: UIViewControllerRepresentable {
    let item: Item

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

}

private actor AttachmentThumbnails {
    static let shared = AttachmentThumbnails()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func image(url: URL, id: String, pixels: Int) async throws -> UIImage {
        // The cached URL also separates identical file ids belonging to different hosts.
        let key = "\(url.absoluteString):\(id):\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = try await Self.downsample(url, pixels: pixels)
        try Task.checkCancellation()
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height) * 4)
        return image
    }

    @concurrent private static func downsample(_ url: URL, pixels: Int) async throws -> UIImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return UIImage(cgImage: image)
    }
}
