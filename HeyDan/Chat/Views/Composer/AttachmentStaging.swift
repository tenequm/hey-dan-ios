import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreTransferable

import HeyDanCore

nonisolated struct PickedPhoto: Transferable {
    let result: Result<StagedAttachment, AppError>
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            do { return PickedPhoto(result: .success(try await AttachmentStaging.photo(received.file))) }
            catch let error as AppError { return PickedPhoto(result: .failure(error)) }
        }
    }
}

nonisolated enum AttachmentStaging {
    static func checkCapacity(_ stagedCount: Int) throws {
        guard stagedCount < Outbox.maximumFiles else {
            throw AppError.limit("Use at most \(Outbox.maximumFiles) files per message.")
        }
    }

    private static func checkSize(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.seekToEnd() <= UInt64(Outbox.maximumFileBytes) else { throw AppError.limit(Outbox.fileLimitMessage) }
    }

    static func destination(extension suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ChatAttachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
    }

    @concurrent static func document(_ source: URL) async throws -> StagedAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        try checkSize(source)
        let target = try destination(extension: source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try checkSize(target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return StagedAttachment(fileURL: target, name: source.lastPathComponent,
                                mimeType: UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
    }

    @concurrent static func photo(_ source: URL) async throws -> StagedAttachment {
        try Task.checkCancellation()
        try checkSize(source)
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
        do {
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            try checkSize(target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
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
