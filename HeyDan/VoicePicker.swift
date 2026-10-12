import Accessibility
import AVFoundation
import HeyDanCore
import Observation
import SwiftUI

@MainActor @Observable
final class VoiceSettingsModel {
    let line: VoiceLine
    private(set) var view: TTSView?
    var draft: TTSChoice?
    private(set) var applied: TTSChoice?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var loadFailure: TTSServiceFailure?
    private(set) var saveFailure: TTSServiceFailure?
    private(set) var saveResult: String?
    private(set) var saveSuccess = 0
    private(set) var voices: [CatalogVoice] = []
    private(set) var catalogLoading = false
    private(set) var catalogFailure: TTSServiceFailure?
    private(set) var next: String?
    var query = ""
    var language = ""
    var gender = ""
    /// The catalog row the caller tapped: its own name labels the draft until the server answers the save.
    private var pickedVoice: CatalogVoice?
    @ObservationIgnored private let session: URLSession
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

    private struct LineKey: Hashable {
        let origin: URL
        let credential: String
        init(_ line: VoiceLine) { origin = line.origin; credential = line.token }
    }
    private static var writes: [LineKey: (id: UUID, task: Task<Void, Never>)] = [:]
    private static var results: [LineKey: String] = [:]
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        #if DEBUG && targetEnvironment(simulator)
        if PickerFixture.scenario != nil { config.protocolClasses = [PickerFixtureProtocol.self] }
        #endif
        return URLSession(configuration: config)
    }()

    init(line: VoiceLine, session: URLSession? = nil) {
        self.line = line
        self.session = session ?? Self.defaultSession
        saveResult = Self.results[LineKey(line)]
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

    var selectedVoice: CatalogVoice? {
        guard let id = draft?.voice else { return nil }
        if let pickedVoice, pickedVoice.id == id { return pickedVoice }
        guard let details = draftDetails, case let .named(name) = VoiceLabel(details) else { return nil }
        return CatalogVoice(id: id, name: name, language: details.language, gender: details.gender, preview: details.preview)
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
        if let write = Self.writes[LineKey(line)] { await write.task.value }
        do {
            let loaded: TTSView = try await fetch(line.ttsRequest)
            guard captured == revision else { loading = false; return }
            adopt(loaded, replaceDraft: draft == nil)
            saveResult = Self.results[LineKey(line)] ?? saveResult
        } catch {
            if captured == revision { loadFailure = failure(error) }
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

    func setVoice(_ voice: CatalogVoice?) {
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
        Self.results[LineKey(line)] = nil
        saveResult = saving
            ? "This line was removed or its access changed. A save already sent may still apply; reopen Voice from Settings to check."
            : "This line was removed or its access changed. Reopen Voice from Settings."
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
        let request: URLRequest
        do { request = try line.ttsPatchRequest(patch) } catch {
            saveResult = "That voice id is too long to save"
            return
        }
        saving = true
        revision = UUID()
        saveFailure = nil
        saveResult = "Saving..."
        let key = LineKey(line)
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
            do {
                let loaded: TTSView = try await fetch(request)
                guard !invalidated else { return }
                adopt(loaded, replaceDraft: true)
                saveResult = reset ? "Saved voice reset to server default" : "Saved for next calls"
                if !reset { saveSuccess += 1 }
            } catch {
                guard !invalidated else { return }
                let failed = failure(error)
                saveFailure = failed
                saveResult = failed.message
                switch failed {
                case .unreachable, .transport, .malformed, .upstream, .refused(status: 500...599, body: _):
                    do {
                        let loaded: TTSView = try await fetch(line.ttsRequest)
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
                        saveResult = "Save not confirmed. \(failure(error).message)"
                    }
                default:
                    if let loaded: TTSView = try? await fetch(line.ttsRequest), !invalidated { adopt(loaded, replaceDraft: false) }
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
        let request = line.voicesRequest(provider: provider, q: key.query.isEmpty ? nil : key.query,
                                        language: key.language.isEmpty ? nil : key.language,
                                        gender: key.gender.isEmpty ? nil : key.gender, cursor: cursor, limit: 50)
        do {
            let page: CatalogPage = try await fetch(request)
            guard generation == catalogGeneration, key == catalogKey, !Task.isCancelled else { return }
            guard page.provider == provider else { throw TTSServiceFailure.malformed }
            if let cursor { usedCursors.insert(cursor) }
            var seen = Set(voices.map(\.id))
            for voice in page.voices where seen.insert(voice.id).inserted { voices.append(voice) }
            next = page.next.flatMap { usedCursors.contains($0) ? nil : $0 }
            catalogFailure = nil
        } catch {
            guard generation == catalogGeneration, key == catalogKey, !Task.isCancelled else { return }
            catalogFailure = failure(error)
        }
        catalogLoading = false
    }

    private func fetch<Value: Decodable>(_ input: URLRequest) async throws -> Value {
        var request = input
        request.timeoutInterval = 12
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw TTSServiceFailure(transportError: error) }
        guard let response = response as? HTTPURLResponse else { throw TTSServiceFailure.malformed }
        CallLog.log(.net, "picker method=\(request.httpMethod ?? "GET") status=\(response.statusCode)")
        guard (200..<300).contains(response.statusCode) else { throw TTSServiceFailure(status: response.statusCode, body: data) }
        do { return try JSONDecoder().decode(Value.self, from: data) } catch { throw TTSServiceFailure.malformed }
    }

    private func failure(_ error: any Error) -> TTSServiceFailure { (error as? TTSServiceFailure) ?? TTSServiceFailure(transportError: error) }
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
    private static var pendingSteps = 0
    private static var latest = UUID()
    private static var playback: SamplePlayback?
    static var isIdle: Bool { pendingSteps == 0 && !owns }

    #if DEBUG
    static var onActivationStarted: (@MainActor () -> Void)?
    static var activationBarrier: (@MainActor () async -> Void)?
    private(set) static var deactivationsAfterHandoff = 0
    private static var handedOff = false
    #endif

    fileprivate static func play(_ voice: CatalogVoice, using owner: SamplePlayback) {
        guard !CallController.shared.isCallActive, let url = voice.preview else { return }
        #if DEBUG
        handedOff = false
        #endif
        release()
        enqueue(activation: true) {
            #if DEBUG
            await activationBarrier?()
            #endif
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
        #if DEBUG
        deactivationsAfterHandoff = 0
        #endif
        release()
        while let pending = work { await pending.value }
        #if DEBUG
        handedOff = true
        #endif
    }

    private static func enqueue(activation: Bool = false, _ step: @escaping @MainActor () async -> Void) {
        let previous = work
        let id = UUID()
        latest = id
        pendingSteps += 1
        work = Task {
            #if DEBUG
            if activation { onActivationStarted?() }
            #endif
            await previous?.value
            await step()
            pendingSteps -= 1
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
            #if DEBUG
            if handedOff { deactivationsAfterHandoff += 1 }
            #endif
            do { try await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) } catch {
                CallLog.log(.audio, "sample release failed", level: .error)
            }
        }
        CallLog.log(.audio, "sample release deactivated=\(deactivate)")
    }
}

struct VoicePickerSheet: View {
    let line: VoiceLine
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
    private let storedLineID: UUID?
    private var samplesUnavailable: Bool { call.isCallActive || call.liveCallID != nil }
    private var liveAvailable: Bool { !model.invalidated && callID != nil && callID == call.liveCallID && call.liveVoice != nil }

    init(line: VoiceLine, agentName: String, callID: UUID?) {
        self.line = line
        self.agentName = agentName
        self.callID = callID
        storedLineID = CallController.shared.lines.entries.first { $0.line == line }?.id
        model = VoiceSettingsModel(line: line)
        sample = SamplePlayback()
    }

    var body: some View {
        NavigationStack(path: $path) {
            summary
                .navigationDestination(for: String.self) { _ in catalog }
        }
        .controlSize(.regular)
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
        .task { await model.load() }
        .onDisappear { model.cancelCatalog(); VoiceSample.release(sample) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { VoiceSample.release(sample) } }
        .onChange(of: call.isCallActive) { _, active in if active { VoiceSample.release(sample) } }
        .onChange(of: call.lines) { _, lines in
            if let storedLineID, lines.entry(storedLineID)?.line != model.line {
                model.invalidate()
                VoiceSample.release(sample)
            }
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

    private var summary: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("\(agentName)'s voice").font(.headline).accessibilityIdentifier(AXID.pickerTitle)
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
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if model.loading { ProgressView("Loading voice settings") }
                if let failure = model.loadFailure {
                    Text(failure.message).foregroundStyle(.red)
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
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
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
            Text(model.saveFailure?.message ?? "").font(.footnote).foregroundStyle(.red)
        }
    }

    private var commits: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.saveResult != nil || liveResult != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let result = model.saveResult { Text("Save: \(result)") }
                    if let result = liveResult { Text("This call: \(result)") }
                }
                .font(.footnote)
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
                .buttonStyle(.glassProminent).frame(minHeight: 44)
                .disabled(!liveAvailable || requesting || model.draft == nil || model.provider?.available != true)
                .accessibilityIdentifier(AXID.pickerUseForCall)
            Button(model.saving ? "Saving..." : "Save for next calls") { Task { await model.save() } }
                .buttonStyle(.glass).frame(minHeight: 44).disabled(!model.canSave)
                .accessibilityIdentifier(AXID.pickerSave)
        } else {
            Button(model.saving ? "Saving..." : "Save for next calls") { Task { await model.save() } }
                .buttonStyle(.glassProminent).frame(minHeight: 44).disabled(!model.canSave)
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
            if samplesUnavailable { Text("Use for this call to hear it on the next reply").font(.footnote) }
            if let failure = sample.failure { Text(failure).foregroundStyle(.red) }
        }
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

    private func catalogRow(_ voice: CatalogVoice) -> some View {
        HStack {
            Button {
                model.setVoice(voice)
                path.removeLast()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.name)
                        let traits = [voice.language, voice.gender?.capitalized].compactMap(\.self)
                        if !traits.isEmpty { Text(traits.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        if let description = voice.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        if voice.preview == nil { Text("No sample available").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if voice.id == model.draft?.voice { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            if voice.preview != nil {
                Button {
                    if sample.playing == voice.id { VoiceSample.release(sample) } else { VoiceSample.play(voice, using: sample) }
                } label: { Image(systemName: sample.playing == voice.id ? "stop.fill" : "play.fill").frame(width: 44, height: 44) }
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
    let title: String
    let caption: String?
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
            if let caption {
                Text(caption).font(.caption2.monospaced()).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
    }
}

#if DEBUG && targetEnvironment(simulator)
private final class PickerFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            do {
                let (status, body) = try PickerFixture.response(request)
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

/// `/voice/tts` and `/voice/voices` as the server answers them, from `HEYDAN_PREVIEW_TTS`. `legacy` is a server from
/// before voice names (no details, no model names, nothing saved); `unavailable` saves a voice the provider no longer
/// has; `lookup-failed` answers the first load with names unavailable and the next with names; `lost-save` applies
/// every PATCH but loses its answer.
@MainActor
enum PickerFixture {
    static let scenario = ProcessInfo.processInfo.environment["HEYDAN_PREVIEW_TTS"]
    private static var savedByLine: [URL: [String: Any]] = [:]
    private static var ttsLoads = 0
    private static let providers = #"[{"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"alnilam"},"modelNames":{"gemini-3.8-flash-tts":"Gemini 3.8 Flash TTS","gemini-3.8-flash-lite-tts":"Gemini 3.8 Flash Lite TTS"}},{"id":"elevenlabs","name":"ElevenLabs","available":true,"models":["eleven_v4_turbo","eleven_v4"],"default":{"model":"eleven_v4_turbo","voice":"bIHbv24MWmeRgasZH58o"},"modelNames":{"eleven_v4_turbo":"Eleven v4 Turbo","eleven_v4":"Eleven v4"}}]"#
    private static let geminiVoices = #"[{"id":"achernar","name":"Achernar","language":"en-US","gender":"female","description":"Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."},{"id":"en-us-techagent-4","name":"Tech Advisor 4","language":"en-US","gender":"male","description":"Tech Support Agent / Tech Advisor. Confident and clear."},{"id":"alnilam","name":"Alnilam","language":"en-US"}]"#
    private static var providerRows: [[String: Any]] { try! JSONSerialization.jsonObject(with: Data(providers.utf8)) as! [[String: Any]] }

    static func response(_ request: URLRequest) throws -> (Int, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        if scenario == "no-route" { return (404, Data()) }
        if scenario == "forbidden", request.httpMethod == "PATCH" || url.path.hasSuffix("voices") { return (403, Data()) }
        if url.path.hasSuffix("voices") {
            if scenario == "catalog-fail" { return (502, Data(#"{"error":"upstream"}"#.utf8)) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let provider = query.first { $0.name == "provider" }?.value ?? "gemini"
            if scenario == "eleven-unavailable", provider == "elevenlabs" { return (503, Data(#"{"error":"provider_unavailable","provider":"elevenlabs"}"#.utf8)) }
            let search = query.first { $0.name == "q" }?.value ?? ""
            let language = query.first { $0.name == "language" }?.value
            let gender = query.first { $0.name == "gender" }?.value
            var rows = try voices(provider).filter { row in
                (search.isEmpty || "\(row["name"] ?? "") \(row["description"] ?? "")".localizedCaseInsensitiveContains(search))
                    && (language == nil || row["language"] as? String == language) && (gender == nil || row["gender"] as? String == gender)
            }
            if scenario == "search-empty" { rows = [] }
            var page: [String: Any] = ["provider": provider, "voices": rows]
            if provider == "gemini", !rows.isEmpty, !query.contains(where: { $0.name == "cursor" }) { page["next"] = "eyJvIjoxMDB9" }
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/voice/tts"
        let key = components.url!
        let legacy = scenario == "legacy"
        let lineDefault: [String: Any] = scenario == "unavailable"
            ? ["provider": "elevenlabs", "model": "eleven_v4_turbo", "voice": "pNInz6obpgDQGcFmaJgB"]
            : ["provider": "gemini", "model": "gemini-3.8-flash-tts", "voice": "en-us-techagent-4"]
        var saved = savedByLine[key] ?? (legacy ? [:] : lineDefault)
        var available = providerRows
        if scenario == "eleven-unavailable" { available[1]["available"] = false }
        if request.httpMethod == "PATCH" {
            let data = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var body = Data()
                var bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    body.append(bytes, count: count)
                }
                return body
            } ?? Data()
            let input = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if input["reset"] as? Bool == true { saved = legacy ? [:] : lineDefault } else {
                guard let id = input["provider"] as? String, let provider = available.first(where: { $0["id"] as? String == id }) else { return (400, Data(#"{"error":"invalid","field":"provider"}"#.utf8)) }
                guard provider["available"] as? Bool == true else { return (503, Data(#"{"error":"provider_unavailable","provider":"elevenlabs"}"#.utf8)) }
                // The server stores the provider default for an omitted model or voice.
                saved = legacy ? input : (provider["default"] as! [String: Any]).merging(input) { $1 }
            }
            savedByLine[key] = saved
            if scenario == "lost-save" { return (502, Data(#"{"error":"upstream"}"#.utf8)) }
        }
        let provider = available.first { $0["id"] as? String == saved["provider"] as? String } ?? available[0]
        let effective = (provider["default"] as! [String: Any]).merging(["provider": provider["id"]!]) { $1 }.merging(saved) { $1 }
        var body: [String: Any] = ["effective": effective, "saved": saved]
        if legacy {
            body["providers"] = available.map { $0.filter { $0.key != "modelNames" } }
        } else {
            ttsLoads += 1
            let status = scenario == "lookup-failed" && ttsLoads == 1 ? "lookup_failed" : nil
            body["details"] = ["saved": try details(saved, status: status), "effective": try details(effective, status: status)]
            body["providers"] = try available.map { row in
                row.merging(["defaultDetails": try details(["provider": row["id"]!], status: status)]) { $1 }
            }
        }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }

    /// What the worker says about a live choice, for the stand-in call.
    static func details(_ choice: TTSChoice) -> ChoiceDetails? {
        let fields = ["provider": choice.provider, "model": choice.model, "voice": choice.voice].compactMapValues(\.self)
        guard let data = try? JSONSerialization.data(withJSONObject: details(fields)) else { return nil }
        return try? JSONDecoder().decode(ChoiceDetails.self, from: data)
    }

    /// `ChoiceDetails` for a choice: names from this catalog, `unavailable` for a voice it does not have.
    private static func details(_ choice: [String: Any], status: String? = nil) throws -> [String: Any] {
        let id = choice["provider"] as? String ?? "gemini"
        let provider = providerRows.first { $0["id"] as? String == id } ?? providerRows[0]
        let defaults = provider["default"] as! [String: Any]
        let model = choice["model"] as? String ?? defaults["model"] as! String
        let voice = choice["voice"] as? String ?? defaults["voice"] as! String
        let row = try voices(id).first { $0["id"] as? String == voice }
        let status = status ?? (row == nil ? "unavailable" : "resolved")
        let named = status == "resolved" ? row : nil
        return ["provider": id, "providerName": provider["name"]!, "model": model,
                "modelName": (provider["modelNames"] as? [String: String])?[model] ?? model, "voice": voice,
                "voiceName": named?["name"] ?? NSNull(), "language": named?["language"] ?? NSNull(),
                "gender": named?["gender"] ?? NSNull(), "preview": named?["preview"] ?? NSNull(), "status": status]
    }

    private static func voices(_ provider: String) throws -> [[String: Any]] {
        guard provider == "elevenlabs" else { return try JSONSerialization.jsonObject(with: Data(geminiVoices.utf8)) as! [[String: Any]] }
        let preview = try sampleURL().absoluteString
        return [["id": "bIHbv24MWmeRgasZH58o", "name": "Will", "language": "en", "gender": "male", "preview": preview],
                ["id": "EXAVITQu4vr4xnSDxMaL", "name": "Sarah", "language": "en", "gender": "female", "preview": preview]]
    }

    private static func sampleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hey-dan-fixture-sample.wav")
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let frames = 8000
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(UInt32(frames * 2))
        for frame in 0..<frames { append(Int16(sin(Double(frame) * 2 * .pi * 440 / 8000) * 2000)) }
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
