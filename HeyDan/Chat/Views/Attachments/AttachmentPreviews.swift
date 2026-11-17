#if DEBUG
import SwiftUI
import HeyDanCore

#Preview("Empty composer") { ComposerView(features: ["files"], send: { _, _ in }) }
#Preview("Typed composer") { ComposerView(features: ["files"], send: { _, _ in }, text: "Hello") }
#Preview("Files off") { ComposerView(send: { _, _ in }) }
#Preview("Staged composer") {
    ComposerView(features: ["files"], send: { _, _ in }, attachments: [
        StagedAttachment(fileURL: URL(fileURLWithPath: "/preview.pdf"), name: "Document.pdf", mimeType: "application/pdf")
    ])
}
#Preview("Portrait loading") {
    AttachmentView(file: FileAttachment(id: "portrait", name: "Portrait", mimeType: "image/jpeg", size: 800_000,
                                        kind: .image, width: 1200, height: 1800)) { _ in
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
#Preview("Landscape failed") {
    AttachmentView(file: FileAttachment(id: "landscape", name: "Landscape", mimeType: "image/jpeg", size: 800_000,
                                        kind: .image, width: 1800, height: 1200))
}
#Preview("PDF and unknown file") {
    VStack {
        AttachmentView(file: FileAttachment(id: "pdf", name: "Document.pdf", mimeType: "application/pdf", size: 12345, kind: .file))
        AttachmentView(file: FileAttachment(id: "unknown", name: "Archive.bin", mimeType: "application/octet-stream", size: 999, kind: .file))
        AttachmentView(attachment: StagedAttachment(fileURL: URL(fileURLWithPath: "/preview.pdf"), name: "Document.pdf", mimeType: "application/pdf"), uploadProgress: 0.4)
    }
}
private enum PreviewImage {
    static func url(width: CGFloat, height: CGFloat) -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let data = renderer.jpegData(withCompressionQuality: 0.85) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(Int(width))-\(Int(height)).jpg")
        try? data.write(to: url)
        return url
    }
}

#Preview("Portrait image") {
    AttachmentView(file: FileAttachment(id: "portrait", name: "Portrait", mimeType: "image/jpeg", size: 800_000,
                                        kind: .image, width: 600, height: 900)) { _ in
        PreviewImage.url(width: 600, height: 900)
    }
}
#Preview("Landscape image") {
    AttachmentView(file: FileAttachment(id: "landscape", name: "Landscape", mimeType: "image/jpeg", size: 800_000,
                                        kind: .image, width: 900, height: 600)) { _ in
        PreviewImage.url(width: 900, height: 600)
    }
}
#endif
