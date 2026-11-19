import SwiftUI
import PhotosUI
import HeyDanCore

struct ComposerView: View {
    @Environment(\.theme) private var theme
    var features: [String]?
    private var availableFeatures: [String] { features ?? ChatController.shared.features }
    let send: (String, [StagedAttachment]) async -> Bool
    /// Why the last send did not queue.
    var failure: String? = nil
    @State var text = ""
    @State var attachments: [StagedAttachment] = []
    @State private var draftFiles = AttachmentDraftFiles()
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var pickingPhotos = false
    @State private var importURLs: [URL] = []
    @State private var staging = false
    @State private var sending = false
    @State private var importFailure: String?
    private static let unreadable = "Could not read the selected attachment. Try selecting it again."
    @FocusState private var textFocused: Bool
    @State private var showsDictationHint = false
    @State private var recording = false

    private var canSend: Bool {
        !staging && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                StagedAttachmentTray(attachments: attachments) { attachment in
                    attachments.removeAll { $0.fileURL == attachment.fileURL }
                    AttachmentStaging.remove(attachment)
                    draftFiles.urls.remove(attachment.fileURL)
                }
            }
            if let shown = importFailure ?? failure {
                Label(shown, systemImage: "exclamationmark.circle")
                    .textRole(theme.type.caption).foregroundStyle(theme.color.danger)
                    .padding(.horizontal, theme.space.s3)
            }
            if showsDictationHint && textFocused {
                Text("Tap the microphone on your keyboard to dictate.")
                    .textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
                    .padding(.horizontal, theme.space.s3).padding(.top, theme.space.s2)
            }
            if recording {
                VoiceRecorder(dismiss: { reason in
                    recording = false
                    importFailure = reason
                }, send: { attachment in
                    recording = false
                    attachments = [attachment]
                    draftFiles.urls.insert(attachment.fileURL)
                    queueMessage()
                })
            } else {
                composerControls
            }
        }
        .onDisappear { recording = false }
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
            case .failure: importFailure = Self.unreadable
            }
        }
        .task(id: importURLs) {
            guard !importURLs.isEmpty else { return }
            await stage(importURLs) { try await AttachmentStaging.document($0) }
            importURLs = []
        }
        .task(id: photos) {
            guard !photos.isEmpty else { return }
            await stage(photos) { photo in
                guard let picked = try await photo.loadTransferable(type: PickedPhoto.self) else { throw CocoaError(.fileReadUnknown) }
                return try picked.result.get()
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

    private var composerControls: some View {
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
                .focused($textFocused)
                .onChange(of: text) { showsDictationHint = false }
                .onChange(of: textFocused) { if !textFocused { showsDictationHint = false } }
                .textRole(theme.type.body)
                .foregroundStyle(theme.color.textPrimary)
                .padding(.horizontal, theme.space.s1).padding(.vertical, theme.space.s2_5)
                .accessibilityIdentifier(AXID.composerText)
            if staging { ProgressView() }
            if availableFeatures.contains("voice-messages"), text.isEmpty, attachments.isEmpty, !staging {
                Button {
                    textFocused = false
                    importFailure = nil
                    recording = true
                } label: {
                    Image(systemName: "mic").foregroundStyle(theme.color.icon)
                        .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                }
                .buttonStyle(.plain).accessibilityLabel("Record voice message")
                .accessibilityIdentifier("composer.record")
                .disabled(CallController.shared.isCallActive)
            } else {
                if !availableFeatures.contains("voice-messages") {
                    Button {
                        textFocused = true
                        showsDictationHint = true
                    } label: {
                        Image(systemName: "mic")
                            .foregroundStyle(theme.color.icon)
                            .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use keyboard dictation")
                    .accessibilityIdentifier(AXID.composerDictation)
                }
                Button { queueMessage() } label: {
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
        }
        .padding(.vertical, theme.space.s0_5)
    }

    private func queueMessage() {
        guard !sending else { return }
        importFailure = nil
        sending = true
        Task {
            defer { sending = false }
            guard await send(text, attachments) else { return }
            if attachments.contains(where: { $0.durationMs != nil }) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            text = ""
            for attachment in attachments { AttachmentStaging.remove(attachment) }
            attachments = []
            draftFiles.urls.removeAll()
        }
    }

    private func stage<Item: Sendable>(_ items: [Item], load: (Item) async throws -> StagedAttachment) async {
        staging = true
        importFailure = nil
        defer { staging = false }
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                try AttachmentStaging.checkCapacity(attachments.count)
                let attachment = try await load(item)
                if Task.isCancelled { AttachmentStaging.remove(attachment); return }
                draftFiles.urls.insert(attachment.fileURL)
                attachments.append(attachment)
            } catch {
                if !Task.isCancelled { importFailure = (error as? AppError)?.message ?? Self.unreadable }
            }
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
        composerRemove = "composer.remove", composerDictation = "composer.dictation"
    static let attachmentOpen = "attachment.open"
}
