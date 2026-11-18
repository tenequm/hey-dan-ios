import SwiftUI
import PhotosUI
import HeyDanCore

struct ComposerView: View {
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
        VStack(alignment: .leading) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["HEYDAN_COMPOSER_CHECKS"] == "1" { ComposerFixtureRows() }
            #endif
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments, id: \.fileURL) { attachment in
                            VStack {
                                AttachmentView(attachment: attachment)
                                Button("Remove", systemImage: "xmark.circle") {
                                    attachments.removeAll { $0.fileURL == attachment.fileURL }
                                    AttachmentStaging.remove(attachment)
                                    draftFiles.urls.remove(attachment.fileURL)
                                }
                                .accessibilityIdentifier(AXID.composerRemove)
                            }.frame(width: 150)
                        }
                    }
                }
            }
            if importFailed {
                Label("Could not read the selected attachment. Try selecting it again.", systemImage: "exclamationmark.circle")
                    .font(.caption)
            }
            HStack(alignment: .bottom) {
                if availableFeatures.contains("files") {
                    Menu {
                        Button("Photos", systemImage: "photo") { pickingPhotos = true }
                            .accessibilityIdentifier(AXID.composerPhotos)
                        Button("Files", systemImage: "doc") { importing = true }
                    } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier(AXID.composerAttach)
                    .disabled(staging)
                }
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier(AXID.composerText)
                if staging { ProgressView() }
                Button("Send", systemImage: "arrow.up.circle.fill") {
                    sending = true
                    Task {
                        defer { sending = false }
                        guard await send(text, attachments) else { return }
                        text = ""
                        for attachment in attachments { AttachmentStaging.remove(attachment) }
                        attachments = []
                        draftFiles.urls.removeAll()
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(staging || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                .accessibilityIdentifier(AXID.composerSend)
            }
        }
        .disabled(sending)
        .padding()
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

extension AXID {
    static let composerText = "composer.text", composerSend = "composer.send",
        composerAttach = "composer.attach", composerPhotos = "composer.photos",
        composerRemove = "composer.remove"
    static let attachmentOpen = "attachment.open"
}
