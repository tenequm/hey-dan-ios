import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreTransferable

import HeyDanCore

nonisolated struct PickedPhoto: Transferable {
    let attachment: StagedAttachment
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedPhoto(attachment: try await AttachmentStaging.photo(received.file))
        }
    }
}

nonisolated enum AttachmentStaging {
    static func destination(extension suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ChatAttachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
    }

    @concurrent static func document(_ source: URL) async throws -> StagedAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        // Before the copy: a file over the limit would be copied whole only to be refused at send.
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Outbox.maximumFileBytes {
            throw AppError.limit(Outbox.fileLimitMessage)
        }
        let target = try destination(extension: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: target)
        return StagedAttachment(fileURL: target, name: source.lastPathComponent,
                                mimeType: UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
    }

    @concurrent static func photo(_ source: URL) async throws -> StagedAttachment {
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let target = try destination(extension: "jpg")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return StagedAttachment(fileURL: target, name: "Photo.jpg", mimeType: "image/jpeg")
    }

    static func remove(_ attachment: StagedAttachment) {
        try? FileManager.default.removeItem(at: attachment.fileURL)
    }
}

@MainActor final class AttachmentDraftFiles {
    var urls: Set<URL> = []

    deinit {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
