import SwiftUI
import PhotosUI
import HeyDanCore

struct ComposerView: View {
    @Environment(\.theme) private var theme
    var features: [String]?
    private var availableFeatures: [String] { features ?? ChatController.shared.features }
    let send: (String, [StagedAttachment]) async -> Bool
    @State var text = ""
    @State var attachments: [StagedAttachment] = []
    @State private var draftFiles = AttachmentDraftFiles()
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var pickingPhotos = false
    @State private var importURLs: [URL] = []
    @State private var staging = false
    @State private var sending = false
    @State private var importFailed = false

    var body: some View {
        let canSend = !staging && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                StagedAttachmentTray(attachments: attachments) { attachment in
                    attachments.removeAll { $0.fileURL == attachment.fileURL }
                    AttachmentStaging.remove(attachment)
                    draftFiles.urls.remove(attachment.fileURL)
                }
            }
            if importFailed {
                Label("Could not read the selected attachment. Try selecting it again.", systemImage: "exclamationmark.circle")
                    .textRole(theme.type.caption).foregroundStyle(theme.color.danger)
                    .padding(.horizontal, theme.space.s3)
            }
            HStack(alignment: .bottom, spacing: 0) {
                if availableFeatures.contains("files") {
                    Menu {
                        Button("Photos", systemImage: "photo") { pickingPhotos = true }
                            .accessibilityIdentifier(AXID.composerPhotos)
                        Button("Files", systemImage: "folder") { importing = true }
                    } label: {
                        Image(systemName: "plus").foregroundStyle(theme.color.icon)
                            .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                    }
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier(AXID.composerAttach)
                    .disabled(staging)
                }
                TextField("Message", text: $text, prompt: Text("Message").foregroundStyle(theme.color.placeholder), axis: .vertical)
                    .lineLimit(1...6)
                    .textRole(theme.type.body)
                    .foregroundStyle(theme.color.textPrimary)
                    .padding(.horizontal, theme.space.s1).padding(.vertical, theme.space.s2_5)
                    .accessibilityIdentifier(AXID.composerText)
                if staging { ProgressView() }
                Button {
                    sending = true
                    Task {
                        defer { sending = false }
                        guard await send(text, attachments) else { return }
                        text = ""
                        for attachment in attachments { AttachmentStaging.remove(attachment) }
                        attachments = []
                        draftFiles.urls.removeAll()
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: theme.type.body.size, weight: theme.weight.bold))
                        .foregroundStyle(canSend ? theme.color.onAccent : theme.color.disabledIcon)
                        .frame(width: theme.type.display.size, height: theme.type.display.size)
                        .background(canSend ? theme.color.accent : theme.color.disabledFill, in: Circle())
                        .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                }
                .buttonStyle(.plain).accessibilityLabel("Send")
                .disabled(!canSend)
                .accessibilityIdentifier(AXID.composerSend)
            }
            .padding(.vertical, theme.space.s0_5)
        }
        .disabled(sending)
        .tint(theme.color.accentText)
        .background(theme.color.composer, in: RoundedRectangle(cornerRadius: theme.radius.composer))
        .overlay { RoundedRectangle(cornerRadius: theme.radius.composer).strokeBorder(theme.color.composerBorder).allowsHitTesting(false) }
        .shadow(color: theme.color.shadow, radius: theme.space.s3_5, y: theme.space.s1_5)
        .padding(.horizontal, theme.space.s3)
        .padding(.bottom, theme.space.s1_5)
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .images)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importURLs = urls
            case .failure: importFailed = true
            }
        }
        .task(id: importURLs) {
            guard !importURLs.isEmpty else { return }
            staging = true
            importFailed = false
            defer { staging = false }
            for url in importURLs {
                do {
                    let attachment = try await AttachmentStaging.document(url)
                    if Task.isCancelled { AttachmentStaging.remove(attachment); return }
                    draftFiles.urls.insert(attachment.fileURL)
                    attachments.append(attachment)
                } catch { if !Task.isCancelled { importFailed = true } }
            }
            importURLs = []
        }
        .task(id: photos) {
            guard !photos.isEmpty else { return }
            staging = true
            importFailed = false
            defer { staging = false }
            for photo in photos {
                do {
                    if let picked = try await photo.loadTransferable(type: PickedPhoto.self) {
                        if Task.isCancelled { AttachmentStaging.remove(picked.attachment); return }
                        draftFiles.urls.insert(picked.attachment.fileURL)
                        attachments.append(picked.attachment)
                    } else { importFailed = true }
                } catch { if !Task.isCancelled { importFailed = true } }
            }
            photos = []
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CHAT"] == "1" || ProcessInfo.processInfo.environment["HEYDAN_CHAT_CHECKS"] == "1",
               availableFeatures.contains("files"), let path = ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_ATTACHMENT"] {
                importURLs = [URL(fileURLWithPath: path)]
            }
            #endif
        }
    }
}

struct StagedAttachmentTray: View {
    @Environment(\.theme) private var theme
    let attachments: [StagedAttachment]
    let remove: (StagedAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: theme.space.s2) {
                ForEach(attachments, id: \.fileURL) { attachment in
                    if attachment.mimeType.hasPrefix("image/") {
                        AttachmentView(attachment: attachment)
                            .overlay(alignment: .topTrailing) { removeButton(attachment) }
                    } else {
                        HStack(spacing: 0) {
                            AttachmentView(attachment: attachment)
                            removeButton(attachment)
                        }
                        .padding(.trailing, theme.space.s1)
                        .background(theme.color.surfaceSubtle, in: RoundedRectangle(cornerRadius: theme.radius.m))
                    }
                }
            }
            .padding(.horizontal, theme.space.s2_5)
        }
        .scrollIndicators(.hidden)
        .padding(.top, theme.space.s2)
    }

    private func removeButton(_ attachment: StagedAttachment) -> some View {
        Button { remove(attachment) } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.color.onAccent, theme.color.backdrop)
                .frame(width: theme.space.s6, height: theme.space.s6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove")
        .accessibilityIdentifier(AXID.composerRemove)
    }
}

extension AXID {
    static let composerText = "composer.text", composerSend = "composer.send",
        composerAttach = "composer.attach", composerPhotos = "composer.photos",
        composerRemove = "composer.remove"
    static let attachmentOpen = "attachment.open"
}
