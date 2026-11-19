import Accessibility
import AVFoundation
import HeyDanCore
import Observation
import SwiftUI

@MainActor @Observable
final class VoiceSettingsModel {
    let service: any VoicePickerService
    private(set) var view: TTSView?
    var draft: TTSChoice?
    private(set) var applied: TTSChoice?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var loadFailure: TTSServiceFailure?
    private(set) var saveFailure: TTSServiceFailure?
    private(set) var saveResult: String?
    private(set) var saveSuccess = 0
    private(set) var voices: [VoiceLineCatalogVoice] = []
    private(set) var catalogLoading = false
    private(set) var catalogFailure: TTSServiceFailure?
    private(set) var next: String?
    var query = ""
    var language = ""
    var gender = ""
    /// The catalog row the caller tapped: its own name labels the draft until the server answers the save.
    private var pickedVoice: VoiceLineCatalogVoice?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    private var catalogGeneration = UUID()
    private var usedCursors: Set<String> = []
    private var revision = UUID()
    private(set) var invalidated = false

    private struct CatalogKey: Equatable {
        let provider: String
        let query: String
        let language: String
        let gender: String
    }
    private var catalogKey: CatalogKey? {
        draft.map { CatalogKey(provider: $0.provider, query: query, language: language, gender: gender) }
    }

    /// Paired 5xx codes that refuse the save outright, so the host's words stand instead of an outcome-unknown re-read.
    private static let definiteRefusals: Set<String> = ["voice_offline", "provider_unavailable"]
    private static var writes: [VoicePickerIdentity: (id: UUID, task: Task<Void, Never>)] = [:]
    private static var results: [VoicePickerIdentity: String] = [:]

    init(service: any VoicePickerService) {
        self.service = service
        saveResult = Self.results[service.identity]
    }

    var provider: TTSProvider? { draft.flatMap { provider($0.provider) } }
    func provider(_ id: String) -> TTSProvider? { view?.providers.first { $0.id == id } }
    var hasChanges: Bool { draft != applied }
    /// A draft the sheet would lose on close; one being saved is not lost, its save goes on.
    var hasUnsavedChanges: Bool { hasChanges && !saving }
    var canSave: Bool { !invalidated && view != nil && draft != nil && hasChanges && provider?.available == true && !saving }
    var languages: [String] { Array(Set(voices.compactMap(\.language))).sorted() }
    /// The server's details for the draft's voice: the saved one, or the provider default the server will use.
    var draftDetails: ChoiceDetails? {
        guard let draft else { return nil }
        if let saved = view?.details?.saved, draft.voice != nil, saved.provider == draft.provider, saved.voice == draft.voice { return saved }
        guard isProviderDefault(draft.voice, provider: draft.provider) else { return nil }
        return provider?.defaultDetails
    }

    var draftVoiceLabel: VoiceLabel {
        if let selectedVoice { return .named(selectedVoice.name) }
        return VoiceLabel(draftDetails, providerDefault: draft.map { isProviderDefault($0.voice, provider: $0.provider) } ?? true)
    }

    /// The Saved row: the saved choice, or the effective one when nothing is saved (an older server).
    var savedVoice: (label: VoiceLabel, name: String, id: String?)? {
        guard let view else { return nil }
        let unsaved = view.saved.isEmpty
        let provider = view.saved.provider ?? view.effective.provider
        let details = unsaved ? view.details?.effective : view.details?.saved
        let label = VoiceLabel(details, providerDefault: isProviderDefault(unsaved ? view.effective.voice : view.saved.voice, provider: provider))
        let name = name(label, provider: provider, details: details)
        return (label, unsaved ? "Server default - \(name)" : name, view.saved.voice ?? view.effective.voice)
    }

    var selectedVoice: VoiceLineCatalogVoice? {
        guard let id = draft?.voice else { return nil }
        if let pickedVoice, pickedVoice.id == id { return pickedVoice }
        guard let details = draftDetails, case let .named(name) = VoiceLabel(details) else { return nil }
        return VoiceLineCatalogVoice(id: id, name: name, language: details.language, gender: details.gender, preview: details.preview)
    }

    /// Names from `/voice/tts` the provider could not be asked for; Retry asks again.
    var namesUnavailable: Bool { savedVoice?.label == .lookupFailed || draftVoiceLabel == .lookupFailed }

    func modelName(_ id: String) -> String { provider?.modelNames?[id] ?? id }

    func name(_ label: VoiceLabel, provider id: String, details: ChoiceDetails? = nil) -> String {
        guard let provider = details?.providerName ?? provider(id)?.name else { return label.title }
        return "\(label.title) (\(provider))"
    }

    /// A live choice's name; a worker that sends no details gets the generic label.
    func name(_ details: ChoiceDetails?, choice: TTSChoice) -> String {
        name(VoiceLabel(details, providerDefault: isProviderDefault(choice.voice, provider: choice.provider)), provider: choice.provider, details: details)
    }

    private func isProviderDefault(_ voice: String?, provider id: String) -> Bool { voice == nil || voice == provider(id)?.default.voice }

    func load() async {
        guard !loading, !saving, !invalidated else { return }
        loading = true
        loadFailure = nil
        let captured = revision
        if let write = Self.writes[service.identity] { await write.task.value }
        do throws(TTSServiceFailure) {
            let loaded: TTSView = try await service.voice()
            guard captured == revision else { loading = false; return }
            adopt(loaded, replaceDraft: draft == nil)
            saveResult = Self.results[service.identity] ?? saveResult
        } catch {
            if captured == revision { loadFailure = error }
        }
        loading = false
    }

    func selectProvider(_ id: String) {
        guard !saving, !invalidated, id != draft?.provider else { return }
        guard provider(id)?.available == true else { return }
        draft = TTSChoice(provider: id)
        pickedVoice = nil
        query = ""
        language = ""
        resetCatalog()
    }

    func setModel(_ id: String?) {
        guard !saving, !invalidated, let draft else { return }
        self.draft = TTSChoice(provider: draft.provider, model: id, voice: draft.voice)
    }

    func setVoice(_ voice: VoiceLineCatalogVoice?) {
        guard !saving, !invalidated, let draft else { return }
        pickedVoice = voice
        self.draft = TTSChoice(provider: draft.provider, model: draft.model, voice: voice?.id)
    }

    func loadCatalog(debounce: Bool = true) async {
        resetCatalog()
        await requestCatalog(cursor: nil, debounce: debounce)
    }

    func loadNext() async {
        guard !catalogLoading, catalogFailure == nil, let next, !usedCursors.contains(next) else { return }
        await requestCatalog(cursor: next)
    }

    func retryCatalog() async {
        guard !catalogLoading else { return }
        catalogFailure = nil
        await requestCatalog(cursor: next)
    }

    func cancelCatalog() { resetCatalog() }

    func invalidate() {
        invalidated = true
        revision = UUID()
        resetCatalog()
        Self.results[service.identity] = nil
        saveResult = saving
            ? "This host is no longer paired. A save already sent may still apply; reopen Voice from Settings to check."
            : "This host is no longer paired. Reopen Voice from Settings."
    }

    private func requestCatalog(cursor: String?, debounce: Bool = false) async {
        guard !invalidated, let key = catalogKey else { return }
        let generation = catalogGeneration
        catalogLoading = true
        let task = Task { [self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await catalogPage(cursor: cursor, generation: generation, key: key)
        }
        catalogTask = task
        await task.value
        if generation == catalogGeneration { catalogTask = nil }
    }

    func save(reset: Bool = false) async {
        guard !saving, !invalidated, let draft, view != nil, reset || provider?.available == true else { return }
        let patch = reset ? TTSPatch.reset : .choice(draft)
        guard (try? JSONEncoder().encode(patch).count) ?? Int.max <= 1024 else {
            saveResult = "That voice id is too long to save"
            return
        }
        saving = true
        revision = UUID()
        saveFailure = nil
        saveResult = "Saving..."
        let key = service.identity
        let previous = Self.writes[key]?.task
        let id = UUID()
        let task = Task { [self] in
            defer {
                if !invalidated { Self.results[key] = saveResult }
                saving = false
                if Self.writes[key]?.id == id { Self.writes[key] = nil }
            }
            await previous?.value
            guard !invalidated else { return }
            do throws(TTSServiceFailure) {
                let loaded: TTSView = try await service.updateVoice(patch)
                guard !invalidated else { return }
                adopt(loaded, replaceDraft: true)
                saveResult = reset ? "Saved voice reset to server default" : "Saved for next calls"
                if !reset { saveSuccess += 1 }
            } catch {
                guard !invalidated else { return }
                let failed = error
                saveFailure = failed
                saveResult = failed.message
                switch failed {
                case .server(status: 500...599, code: let code, message: _) where Self.definiteRefusals.contains(code):
                    if let loaded: TTSView = try? await service.voice(), !invalidated { adopt(loaded, replaceDraft: false) }
                case .pairedTransport, .malformed, .server(status: 500...599, code: _, message: _):
                    do throws(TTSServiceFailure) {
                        let loaded: TTSView = try await service.voice()
                        guard !invalidated else { return }
                        let matches = loaded.confirms(patch)
                        adopt(loaded, replaceDraft: matches)
                        saveResult = matches
                            ? (reset ? "Saved voice reset to server default (confirmed after retry)" : "Saved for next calls (confirmed after retry)")
                            : "Save not confirmed. Saved state refreshed; check it before retrying."
                        if matches {
                            saveFailure = nil
                            if !reset { saveSuccess += 1 }
                        }
                    } catch {
                        guard !invalidated else { return }
                        saveResult = "Save not confirmed. \(error.message)"
                    }
                default:
                    if let loaded: TTSView = try? await service.voice(), !invalidated { adopt(loaded, replaceDraft: false) }
                }
            }
        }
        Self.writes[key] = (id, task)
        await task.value
    }

    private func adopt(_ loaded: TTSView, replaceDraft: Bool) {
        view = loaded
        if replaceDraft {
            let saved = loaded.saved
            draft = TTSChoice(provider: saved.provider ?? loaded.effective.provider, model: saved.model, voice: saved.voice)
            applied = draft
            pickedVoice = nil
        }
    }

    private func resetCatalog() {
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration = UUID()
        voices = []
        usedCursors = []
        next = nil
        catalogFailure = nil
        catalogLoading = false
    }

    private func catalogPage(cursor: String?, generation: UUID, key: CatalogKey) async {
        let provider = key.provider
        let request = VoiceCatalogQuery(provider: provider, q: key.query.isEmpty ? nil : key.query,
                                        language: key.language.isEmpty ? nil : key.language,
                                        gender: key.gender.isEmpty ? nil : key.gender, cursor: cursor, limit: 50)
        do throws(TTSServiceFailure) {
            let page: CatalogPage = try await service.voices(request)
            guard generation == catalogGeneration, key == catalogKey, !Task.isCancelled else { return }
            guard page.provider == provider else { throw TTSServiceFailure.malformed }
            if let cursor { usedCursors.insert(cursor) }
            var seen = Set(voices.map(\.id))
            for voice in page.voices where seen.insert(voice.id).inserted { voices.append(voice) }
            next = page.next.flatMap { usedCursors.contains($0) ? nil : $0 }
            catalogFailure = nil
        } catch {
            guard generation == catalogGeneration, key == catalogKey, !Task.isCancelled else { return }
            catalogFailure = error
        }
        catalogLoading = false
    }

}

@MainActor @Observable
private final class SamplePlayback {
    @ObservationIgnored lazy var player = AVPlayer()
    var playing: String?
    var failure: String?
    var item: AVPlayerItem?
    var statusObservation: NSKeyValueObservation?
    var observers: [NSObjectProtocol] = []
}

@MainActor
enum VoiceSample {
    private static var owns = false
    private static var work: Task<Void, Never>?
    private static var latest = UUID()
    private static var playback: SamplePlayback?
    fileprivate static func play(_ voice: VoiceLineCatalogVoice, using owner: SamplePlayback) {
        guard !CallController.shared.isCallActive, let url = voice.preview else { return }
        release()
        enqueue {
            playback = owner
            owner.failure = nil
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try await session.activate(options: [])
                owns = true
                let item = AVPlayerItem(url: url)
                owner.item = item
                owner.playing = voice.id
                owner.player.replaceCurrentItem(with: item)
                for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
                    owner.observers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { _ in
                        Task { @MainActor in
                            guard owner.item === item else { return }
                            if name == AVPlayerItem.failedToPlayToEndTimeNotification { owner.failure = "Could not play this voice sample" }
                            release(owner, item: item)
                        }
                    })
                }
                owner.statusObservation = item.observe(\.status) { item, _ in
                    let failed = item.status == .failed
                    Task { @MainActor in
                        guard failed, owner.item === item else { return }
                        owner.failure = "Could not play this voice sample"
                        release(owner, item: item)
                    }
                }
                owner.player.play()
                CallLog.log(.audio, "sample activate ok")
            } catch {
                owner.failure = "Could not play this voice sample"
                await releaseOwned()
            }
        }
    }

    fileprivate static func release(_ owner: SamplePlayback? = nil, item: AVPlayerItem? = nil) {
        enqueue {
            guard owner == nil || playback === owner else { return }
            guard item == nil || playback?.item === item else { return }
            await releaseOwned()
        }
    }

    static func stop() async {
        release()
        while let pending = work { await pending.value }
    }

    private static func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = work
        let id = UUID()
        latest = id
        work = Task {
            await previous?.value
            await step()
            if latest == id { work = nil }
        }
    }

    private static func releaseOwned() async {
        if let owner = playback {
            owner.player.pause()
            owner.player.replaceCurrentItem(with: nil)
            owner.item = nil
            owner.playing = nil
            owner.statusObservation = nil
            for observer in owner.observers { NotificationCenter.default.removeObserver(observer) }
            owner.observers = []
        }
        playback = nil
        let deactivate = owns
        if owns {
            owns = false
            do { try await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) } catch {
                CallLog.log(.audio, "sample release failed", level: .error)
            }
        }
        CallLog.log(.audio, "sample release deactivated=\(deactivate)")
    }
}

struct VoicePickerSheet: View {
    @Environment(\.theme) private var theme
    let agentName: String
    let callID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: VoiceSettingsModel
    @State private var sample: SamplePlayback
    @State private var path: [String] = []
    @State private var detent: PresentationDetent = .medium
    @State private var resetting = false
    @State private var closing = false
    @State private var requesting = false
    @State private var liveResult: String?
    @State private var queuedChoice: TTSChoice?
    /// The live choice the result line reports active; a later post naming it updates the line.
    @State private var confirmedChoice: TTSChoice?
    /// This call's worker names its voices: a state it posts without names is followed by one with them.
    @State private var workerNamesVoices = false
    @State private var lastAnnouncement: String?
    @State private var customLanguage = ""
    @State private var languagePrompt = false
    private var call: CallController { .shared }
    private var pairingAvailable: Bool {
        let identity = model.service.identity
        return Pairings.shared.entries.contains { entry in
            if case let .paired(host, device, _) = identity { return entry.host == host && entry.deviceId == device }
            return false
        }
    }
    private var samplesUnavailable: Bool { call.isCallActive || call.liveCallID != nil }
    private var liveAvailable: Bool { !model.invalidated && callID != nil && callID == call.liveCallID && call.liveVoice != nil }

    init(service: any VoicePickerService, agentName: String, callID: UUID?) {
        self.init(model: VoiceSettingsModel(service: service), agentName: agentName, callID: callID)
    }

    init(model: VoiceSettingsModel, agentName: String, callID: UUID?) {
        self.agentName = agentName
        self.callID = callID
        self.model = model
        sample = SamplePlayback()
        if callID == nil { _detent = State(initialValue: .large) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if case let .paired(host, _, _) = model.service.identity, callID == nil {
                    pairedSummary(host: host)
                } else { summary }
            }
            .navigationDestination(for: String.self) { _ in catalog }
        }
        .controlSize(.regular)
        .tint(theme.color.accentText)
        .foregroundStyle(theme.color.textPrimary)
        .presentationBackground(theme.color.surfaceSheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .dismissalConfirmationDialog("Discard voice changes?", shouldPresent: model.hasUnsavedChanges) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
        .confirmationDialog("Discard voice changes?", isPresented: $closing, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
        .confirmationDialog("Reset saved voice to server default?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset saved voice", role: .destructive) { Task { await model.save(reset: true) } }
        } message: { Text("This changes future calls for every client. This call keeps its voice.") }
        .alert("Language code", isPresented: $languagePrompt) {
            TextField("For example, en-US", text: $customLanguage).textInputAutocapitalization(.never)
            Button("Apply") { model.language = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Use the provider's exact language code. Suggestions are from loaded voices only.") }
        .task { if model.view == nil { await model.load() } }
        .onDisappear { model.cancelCatalog(); VoiceSample.release(sample) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { VoiceSample.release(sample) } }
        .onChange(of: call.isCallActive) { _, active in if active { VoiceSample.release(sample) } }
        .onChange(of: pairingAvailable) { _, available in
            if !available { model.invalidate(); VoiceSample.release(sample) }
        }
        .onChange(of: call.liveVoice) { old, new in
            guard callID != nil, callID == call.liveCallID else { return }
            if old?.activeDetails != nil { workerNamesVoices = true }
            if let new, let pending = new.pending, pending != old?.pending || new.pendingDetails != old?.pendingDetails {
                if speaks(new.pendingDetails) { announce("\(model.name(new.pendingDetails, choice: pending)) from \(agentName)'s next reply") }
            } else if let new, new.pending == nil, old?.pending != nil || old?.active != new.active || old?.activeDetails != new.activeDetails {
                if speaks(new.activeDetails) { announce("\(model.name(new.activeDetails, choice: new.active)) configured for this call") }
            }
            updateLiveResult()
        }
        .onChange(of: call.liveCallID) { _, _ in
            if callID != nil && callID != call.liveCallID { liveResult = "This call has ended. You can still save for next calls." }
        }
        .sensoryFeedback(.success, trigger: model.saveSuccess) { old, new in
            old != new && callID == nil && !samplesUnavailable
        }
    }

    private func pairedSummary(host: URL) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack {
                    VStack(alignment: .leading, spacing: theme.space.s1) {
                        Text("\(agentName)'s voice").textRole(theme.type.body, theme.weight.bold)
                            .accessibilityIdentifier(AXID.pickerTitle)
                        Text("Saved on \(host.host() ?? "host") · used by every paired phone")
                            .textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
                    }
                    Spacer()
                    GlassIconButton(title: "Close", systemImage: "xmark") {
                        if model.hasUnsavedChanges { closing = true } else { dismiss() }
                    }
                    .accessibilityIdentifier(AXID.pickerClose)
                }
                if model.loading { ProgressView("Loading voice settings") }
                if let failure = model.loadFailure {
                    Text(failure.message).foregroundStyle(theme.color.danger)
                    Button("Retry") { Task { await model.load() } }.accessibilityIdentifier(AXID.pickerRetry)
                }
                if let view = model.view, let draft = model.draft {
                    SettingsSection("Provider") {
                        ForEach(view.providers, id: \.id) { provider in
                            choice(provider.name, subtitle: provider.available ? "Configured on the host" : "Not configured on the host",
                                   selected: provider.id == draft.provider) { model.selectProvider(provider.id) }
                                .disabled(!provider.available || model.saving || model.invalidated)
                        }
                        fieldFailure("provider")
                    }
                    .accessibilityIdentifier(AXID.pickerProvider)
                    SettingsSection("Voice") {
                        ForEach(model.voices.prefix(3), id: \.id) { voice in
                            choice(voice.name, subtitle: voice.description ?? voice.language, selected: draft.voice == voice.id) {
                                model.setVoice(voice)
                            }
                        }
                        Button { path.append("catalog") } label: {
                            SettingsRow(title: "Choose a voice", icon: "waveform", detail: model.draftVoiceLabel.title, navigates: true)
                        }
                        .accessibilityIdentifier(AXID.pickerVoice)
                        fieldFailure("voice")
                    }
                    .disabled(model.saving || model.invalidated)
                    SettingsSection {
                        Picker("Model", selection: Binding(get: { model.draft?.model ?? model.provider?.default.model }, set: model.setModel)) {
                            ForEach(model.provider?.models ?? [], id: \.self) { Text(model.modelName($0)).tag(Optional($0)) }
                            if let id = draft.model, !(model.provider?.models.contains(id) ?? false) { Text(model.modelName(id)).tag(Optional(id)) }
                        }
                        .padding(theme.space.s4).accessibilityIdentifier(AXID.pickerModel)
                        fieldFailure("model")
                        Menu {
                            Button("All languages") { model.language = "" }
                            ForEach(model.languages, id: \.self) { code in Button(code) { model.language = code } }
                            Button("Enter language code...") { customLanguage = model.language; languagePrompt = true }
                        } label: {
                            SettingsRow(title: "Language", icon: "globe", detail: model.language.isEmpty ? "All" : model.language, navigates: true)
                        }
                    }
                    .disabled(model.saving || model.invalidated)
                    if let saved = model.savedVoice {
                        voiceRow("Saved for next calls", saved.name, caption: saved.label.caption(saved.id))
                            .accessibilityIdentifier(AXID.pickerSaved)
                        if model.namesUnavailable {
                            Button("Retry voice names") { Task { await model.load() } }.accessibilityIdentifier(AXID.pickerNameRetry)
                        }
                    }
                    Button("Reset saved voice to server default", role: .destructive) { resetting = true }
                        .disabled(model.saving || model.invalidated).accessibilityIdentifier(AXID.pickerReset)
                }
            }
            .buttonStyle(.plain).padding(theme.space.s4)
        }
        .background(theme.color.surfaceSheet)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { commits.background(theme.color.surfaceSheet) }
        .task(id: "\(path.isEmpty)-\(model.draft?.provider ?? "")-\(model.language)") {
            if path.isEmpty, model.provider != nil { await model.loadCatalog(debounce: false) }
        }
    }

    private func choice(_ title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: theme.space.s3) {
                VStack(alignment: .leading, spacing: theme.space.s1) {
                    Text(title).textRole(theme.type.body)
                    if let subtitle { Text(subtitle).textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(theme.color.accentText) }
            }
            .padding(.horizontal, theme.space.s4).padding(.vertical, theme.space.s3).contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var summary: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("\(agentName)'s voice").textRole(theme.type.headline, theme.weight.bold).accessibilityIdentifier(AXID.pickerTitle)
                    if let saved = model.savedVoice {
                        voiceRow("Saved for next calls", saved.name, caption: saved.label.caption(saved.id), loading: model.loading)
                            .accessibilityIdentifier(AXID.pickerSaved)
                        if model.namesUnavailable && model.loadFailure == nil {
                            Button("Retry") { Task { await model.load() } }
                                .disabled(model.loading || model.saving || model.invalidated).accessibilityIdentifier(AXID.pickerNameRetry)
                        }
                    } else if model.loadFailure == nil {
                        voiceRow("Saved for next calls", "Loading voice name", caption: nil, loading: true)
                            .accessibilityIdentifier(AXID.pickerSaved)
                    }
                    // The worker looks names up again itself and posts them, so a live row has no Retry.
                    if callID != nil, callID == call.liveCallID, let state = call.liveVoice {
                        voiceRow("This call", model.name(state.activeDetails, choice: state.active),
                                 caption: VoiceLabel(state.activeDetails).caption(state.active.voice))
                            .accessibilityIdentifier(AXID.pickerLive)
                        if let pending = state.pending {
                            voiceRow("Next spoken line", model.name(state.pendingDetails, choice: pending),
                                     caption: VoiceLabel(state.pendingDetails).caption(pending.voice))
                                .accessibilityIdentifier(AXID.pickerNext)
                        }
                        Text("The current spoken line finishes unchanged. These are configured voices; the worker may use a fallback.")
                            .textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary)
                    }
                }
                if model.loading { ProgressView("Loading voice settings") }
                if let failure = model.loadFailure {
                    Text(failure.message).foregroundStyle(theme.color.danger)
                    Button("Retry") { Task { await model.load() } }.accessibilityIdentifier(AXID.pickerRetry)
                }
                if let view = model.view, let draft = model.draft {
                    Section(model.hasChanges ? "Draft voice" : "Voice") {
                        Menu {
                            ForEach(view.providers, id: \.id) { provider in
                                Button { model.selectProvider(provider.id) } label: {
                                    LabeledContent {
                                        Text(provider.available ? "" : "Not configured on server")
                                    } label: {
                                        if provider.id == draft.provider { Label(provider.name, systemImage: "checkmark") }
                                        else { Text(provider.name) }
                                    }
                                }
                                .disabled(!provider.available)
                            }
                        } label: { LabeledContent("Provider", value: model.provider?.name ?? draft.provider) }
                        .accessibilityIdentifier(AXID.pickerProvider)
                        fieldFailure("provider")
                        // An omitted model is the provider default, the one the server saves for it.
                        Picker("Model", selection: Binding(get: { model.draft?.model ?? model.provider?.default.model }, set: model.setModel)) {
                            ForEach(model.provider?.models ?? [], id: \.self) { Text(model.modelName($0)).tag(Optional($0)) }
                            if let id = draft.model, !(model.provider?.models.contains(id) ?? false) { Text(model.modelName(id)).tag(Optional(id)) }
                        }
                        .pickerStyle(.menu).accessibilityIdentifier(AXID.pickerModel)
                        fieldFailure("model")
                        Button {
                            detent = .large
                            path.append("catalog")
                        } label: {
                            LabeledContent("Voice") {
                                let label = model.draftVoiceLabel
                                VoiceName(title: label.title, caption: label.caption(draft.voice ?? model.provider?.default.voice))
                            }
                        }
                        .accessibilityIdentifier(AXID.pickerVoice)
                        fieldFailure("voice")
                    }
                    .disabled(model.saving || model.invalidated)
                    if callID != nil && !liveAvailable {
                        Text(callID == call.liveCallID ? "This worker does not report voice settings. Live switching is unavailable." : "This call has ended. You can still save for next calls.")
                            .textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(theme.color.surfaceSheet)
            .clipped()
        }
        .navigationTitle("\(agentName)'s voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { if model.hasUnsavedChanges { closing = true } else { dismiss() } }
                    .accessibilityIdentifier(AXID.pickerClose)
            }
            ToolbarOverflowMenu {
                Button("Reset saved voice to server default...", role: .destructive) { resetting = true }
                    .disabled(model.invalidated || model.view == nil || model.saving).accessibilityIdentifier(AXID.pickerReset)
            }
        }
        .safeAreaBar(edge: .bottom) { commits }
    }

    /// A voice as the server names it; VoiceOver reads the name or placeholder, never the id caption.
    private func voiceRow(_ title: String, _ name: String, caption: String?, loading: Bool = false) -> some View {
        LabeledContent(title) { VoiceName(title: name, caption: caption) }
            .redacted(reason: loading ? .placeholder : [])
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(loading ? "Loading" : name)
    }

    @ViewBuilder private func fieldFailure(_ field: String) -> some View {
        if case let .invalid(name) = model.saveFailure, name == field || name == "tts" {
            Text(model.saveFailure?.message ?? "").textRole(theme.type.footnote).foregroundStyle(theme.color.danger)
        }
    }

    private var commits: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            if model.saveResult != nil || liveResult != nil {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    if let result = model.saveResult { Text("Save: \(result)") }
                    if let result = liveResult { Text("This call: \(result)") }
                }
                .textRole(theme.type.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine).accessibilityIdentifier(AXID.pickerResult)
            }
            GlassEffectContainer {
                ViewThatFits(in: .horizontal) {
                    HStack { commitButtons }
                    VStack { commitButtons }
                }
            }
        }
        .padding()
    }

    @ViewBuilder private var commitButtons: some View {
        if callID != nil {
            Button(requesting ? "Requesting..." : "Use for this call") { Task { await useForCall() } }
                .buttonStyle(.glassProminent).frame(minHeight: theme.control.touchTarget)
                .disabled(!liveAvailable || requesting || model.draft == nil || model.provider?.available != true)
                .accessibilityIdentifier(AXID.pickerUseForCall)
            Button(model.saving ? "Saving..." : "Save for next calls") { Task { await model.save() } }
                .buttonStyle(.glass).frame(minHeight: theme.control.touchTarget).disabled(!model.canSave)
                .accessibilityIdentifier(AXID.pickerSave)
        } else {
            Button(model.saving ? "Saving..." : "Save voice") { Task { await model.save() } }
                .buttonStyle(PanelActionStyle()).disabled(!model.canSave)
                .accessibilityIdentifier(AXID.pickerSave)
        }
    }

    private var catalog: some View {
        List {
            Section("Current selection") {
                if let voice = model.selectedVoice {
                    catalogRow(voice)
                } else if let id = model.draft?.voice {
                    HStack {
                        let label = model.draftVoiceLabel
                        VoiceName(title: label.title, caption: label.caption(id), alignment: .leading)
                        Spacer()
                        Image(systemName: "checkmark").accessibilityLabel("Selected")
                    }
                    .accessibilityElement(children: .combine)
                }
                Button { model.setVoice(nil); path.removeLast() } label: {
                    HStack {
                        Text("Provider default voice")
                        Spacer()
                        if model.draft?.voice == nil { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                    }
                }
            }
            Section {
                let selectedID = model.draft?.voice
                ForEach(model.voices.filter { $0.id != selectedID }, id: \.id) { catalogRow($0) }
                if model.catalogLoading { ProgressView("Loading voices") }
                if let failure = model.catalogFailure {
                    ContentUnavailableView {
                        Label("Could not load voices", systemImage: "exclamationmark.triangle")
                    } description: { Text(failure.message) } actions: {
                        Button("Retry") { Task { await model.retryCatalog() } }.accessibilityIdentifier(AXID.pickerRetry)
                    }
                } else if !model.catalogLoading && model.voices.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if let next = model.next {
                    ProgressView("More voices").id(next).onAppear { Task { await model.loadNext() } }
                }
            }
            if samplesUnavailable { Text("Use for this call to hear it on the next reply").textRole(theme.type.footnote) }
            if let failure = sample.failure { Text(failure).foregroundStyle(theme.color.danger) }
        }
        .scrollContentBackground(.hidden).background(theme.color.surfaceSheet)
        .navigationTitle("Choose a voice")
        .searchable(text: $model.query, prompt: "Search voices")
        .accessibilityIdentifier(AXID.pickerSearch)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Gender", selection: $model.gender) {
                        Text("All genders").tag("")
                        Text("Female").tag("female")
                        Text("Male").tag("male")
                    }
                    Divider()
                    Button("All languages") { model.language = "" }
                    ForEach(model.languages, id: \.self) { code in Button(code) { model.language = code } }
                    Button("Enter language code...") { customLanguage = model.language; languagePrompt = true }
                } label: {
                    Label("Language code: \(model.language.isEmpty ? "All" : model.language), Gender: \(model.gender.isEmpty ? "All" : model.gender.capitalized)",
                          systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier(AXID.pickerFilter)
            }
        }
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .task(id: "\(model.draft?.provider ?? "")\n\(model.query)\n\(model.language)\n\(model.gender)") { await model.loadCatalog() }
        .onDisappear { model.cancelCatalog(); VoiceSample.release(sample) }
    }

    private func catalogRow(_ voice: VoiceLineCatalogVoice) -> some View {
        HStack {
            Button {
                model.setVoice(voice)
                path.removeLast()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: theme.space.s1) {
                        Text(voice.name)
                        let traits = [voice.language, voice.gender?.capitalized].compactMap(\.self)
                        if !traits.isEmpty { Text(traits.joined(separator: ", ")).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary) }
                        if let description = voice.description { Text(description).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary) }
                        if voice.preview == nil { Text("No sample available").textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary) }
                    }
                    Spacer()
                    if voice.id == model.draft?.voice { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                }
                .frame(minHeight: theme.control.touchTarget)
            }
            .buttonStyle(.plain)
            if voice.preview != nil {
                Button {
                    if sample.playing == voice.id { VoiceSample.release(sample) } else { VoiceSample.play(voice, using: sample) }
                } label: { Image(systemName: sample.playing == voice.id ? "stop.fill" : "play.fill").frame(width: theme.control.touchTarget, height: theme.control.touchTarget) }
                    .buttonStyle(.glass).disabled(samplesUnavailable || model.invalidated)
                    .accessibilityLabel("Voice sample: \(voice.name)")
                    .accessibilityHint(samplesUnavailable ? "Use for this call to hear it on the next reply" : "Sample does not demonstrate the selected model")
                    .accessibilityIdentifier(AXID.pickerSample(voice.id))
            }
        }
    }

    private func useForCall() async {
        guard liveAvailable, !requesting, let callID, let draft = model.draft else { return }
        let draftName = model.name(model.draftVoiceLabel, provider: draft.provider)
        requesting = true
        queuedChoice = nil
        confirmedChoice = nil
        liveResult = "Requesting live change..."
        let outcome = await call.requestVoice(draft, for: callID)
        requesting = false
        guard callID == call.liveCallID else { liveResult = "This call has ended. You can still save for next calls."; return }
        switch outcome {
        case .queued:
            queuedChoice = draft
            liveResult = "Queued for the next spoken line. The current spoken line finishes unchanged."
            announce("\(draftName) from \(agentName)'s next reply")
            updateLiveResult()
        case let .refused(reason):
            liveResult = reason == "tts_unavailable" ? "That provider is unavailable. Choose another voice." : "The live voice change was refused. Choose another voice."
            await model.load()
        case .unconfirmed:
            queuedChoice = draft
            liveResult = "Change not confirmed. Check This call and Next spoken line before retrying."
            updateLiveResult()
        case .unsupported: liveResult = "This worker does not support live voice switching."
        case .over: liveResult = "This call has ended. You can still save for next calls."
        }
    }

    private func updateLiveResult() {
        guard callID == call.liveCallID, let state = call.liveVoice else { return }
        if let confirmed = confirmedChoice {
            guard state.pending == nil, state.active == confirmed else { confirmedChoice = nil; return }
            liveResult = "Active for this call: \(model.name(state.activeDetails, choice: state.active))"
            return
        }
        guard let choice = queuedChoice else { return }
        let expectedModel = choice.model ?? model.provider(choice.provider)?.default.model
        let expectedVoice = choice.voice ?? model.provider(choice.provider)?.default.voice
        if state.pending == nil, state.active.provider == choice.provider,
           state.active.model == expectedModel || state.active.model == choice.model,
           state.active.voice == expectedVoice || state.active.voice == choice.voice {
            let name = model.name(state.activeDetails, choice: state.active)
            liveResult = "Active for this call: \(name)"
            queuedChoice = nil
            confirmedChoice = state.active
            if speaks(state.activeDetails) { announce("\(name) configured for this call") }
        }
    }

    /// A state posted without names is spoken only by a worker that never sends them; one that does follows it up.
    private func speaks(_ details: ChoiceDetails?) -> Bool { details != nil || !workerNamesVoices }

    private func announce(_ message: String) {
        guard message != lastAnnouncement else { return }
        lastAnnouncement = message
        var text = AttributedString(message)
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}

private extension VoiceLabel {
    /// A label without a name shows the voice id under it.
    func caption(_ id: String?) -> String? {
        if case .named = self { nil } else { id }
    }
}

/// A voice name; without one, the id shows under the placeholder as a small caption VoiceOver skips.
private struct VoiceName: View {
    @Environment(\.theme) private var theme
    let title: String
    let caption: String?
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: theme.space.s0_5) {
            Text(title)
            if let caption {
                Text(caption).textRole(theme.type.micro, mono: true).foregroundStyle(theme.color.textSecondary).accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
    }
}
