import SwiftUI
import HeyDanCore
import ImageIO
import UniformTypeIdentifiers
import QuickLook

struct AttachmentView: View {
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
    @State private var openWhenLoaded = false

    init(file: FileAttachment, download: @escaping (FileAttachment) async throws -> URL = { file in
        try await ChatController.shared.download(file)
    }) {
        self.file = file
        self.download = download
        localURL = nil
    }

    init(attachment: StagedAttachment) {
        let type = UTType(mimeType: attachment.mimeType)
        file = FileAttachment(id: attachment.fileURL.absoluteString, name: attachment.name,
                              mimeType: attachment.mimeType, size: 0,
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let loadedURL { previewURL = loadedURL }
                else { openWhenLoaded = true; requested = true; attempt += 1 }
            } label: {
                VStack(alignment: .leading) {
                    if file.kind == .image {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                            if let thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFit()
                            } else if failure == nil { ProgressView() }
                        }
                        .frame(maxWidth: 240)
                        .frame(height: imageHeight)
                        .clipped()
                    } else { Image(systemName: icon).font(.title) }
                    Text(file.name).lineLimit(2)
                    if localURL == nil { Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AXID.attachmentOpen)
            if requested && loadedURL == nil && failure == nil && file.kind != .image { ProgressView() }
            if let failure {
                Text(failure).font(.caption)
                Button("Retry") { attempt += 1 }
            }
            if let loadedURL {
                ShareLink(item: loadedURL)
            }
        }
        .quickLookPreview($previewURL)
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
                if openWhenLoaded { previewURL = url; openWhenLoaded = false }
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
