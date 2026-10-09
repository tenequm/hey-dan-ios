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
    private struct VoiceKey: Hashable {
        let provider: String
        let id: String
    }
    private var knownVoices: [VoiceKey: CatalogVoice] = [:]
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
    }
    private var catalogKey: CatalogKey? {
        draft.map { CatalogKey(provider: $0.provider, query: query, language: language) }
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

    var provider: TTSProvider? { view?.providers.first { $0.id == draft?.provider } }
    var hasChanges: Bool { draft != applied }
    var canSave: Bool { !invalidated && view != nil && draft != nil && hasChanges && provider?.available == true && !saving }
    var languages: [String] { Array(Set(voices.compactMap(\.language))).sorted() }
    var selectedVoice: CatalogVoice? {
        guard let draft, let id = draft.voice else { return nil }
        guard let voice = knownVoice(provider: draft.provider, id: id) else { return CatalogVoice(id: id, name: id) }
        return CatalogVoice(id: id, name: voice.name, language: voice.language, gender: voice.gender,
                            description: voice.description, preview: voice.preview)
    }

    func name(_ choice: TTSChoice) -> String {
        let provider = view?.providers.first { $0.id == choice.provider }
        let id = choice.voice ?? provider?.default.voice
        let name = id.map { knownVoice(provider: choice.provider, id: $0)?.name ?? $0 } ?? "Provider default voice"
        return "\(name) (\(provider?.name ?? choice.provider))"
    }

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
        guard view?.providers.first(where: { $0.id == id })?.available == true else { return }
        draft = TTSChoice(provider: id)
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
        saveResult = "This line was removed or its access changed. Reopen Voice from Settings."
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
                if !reset && !CallController.shared.isCallActive { saveSuccess += 1 }
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
                        adopt(loaded, replaceDraft: false)
                        let matches = reset ? loaded.saved.isEmpty : loaded.saved == SavedTTSChoice(
                            provider: draft.provider, model: draft.model, voice: draft.voice
                        )
                        saveResult = matches
                            ? (reset ? "Saved voice reset to server default (confirmed after retry)" : "Saved for next calls (confirmed after retry)")
                            : "Save not confirmed. Saved state refreshed; check it before retrying."
                        if matches {
                            saveFailure = nil
                            applied = self.draft
                            if reset { adopt(loaded, replaceDraft: true) }
                            if !reset && !CallController.shared.isCallActive { saveSuccess += 1 }
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
                                        language: key.language.isEmpty ? nil : key.language, cursor: cursor, limit: 50)
        do {
            let page: CatalogPage = try await fetch(request)
            guard generation == catalogGeneration, key == catalogKey, !Task.isCancelled else { return }
            guard page.provider == provider else { throw TTSServiceFailure.malformed }
            if let cursor { usedCursors.insert(cursor) }
            var seen = Set(voices.map { voiceKey(provider, $0.id) })
            for voice in page.voices {
                let key = voiceKey(provider, voice.id)
                knownVoices[key] = voice
                if seen.insert(key).inserted { voices.append(voice) }
            }
            next = page.next.flatMap { usedCursors.contains($0) ? nil : $0 }
            catalogFailure = nil
        } catch {
            guard generation == catalogGeneration, key == catalogKey, !Task.isCancelled else { return }
            catalogFailure = failure(error)
        }
        catalogLoading = false
    }

    private func knownVoice(provider: String, id: String) -> CatalogVoice? {
        knownVoices[voiceKey(provider, id)] ?? knownVoices.first {
            $0.key.provider == provider && $0.value.id.caseInsensitiveCompare(id) == .orderedSame
        }?.value
    }

    private func voiceKey(_ provider: String, _ id: String) -> VoiceKey { VoiceKey(provider: provider, id: id) }

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
        .dismissalConfirmationDialog("Discard voice changes?", shouldPresent: model.hasChanges) {
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
        .onChange(of: line) { _, newLine in
            if newLine != model.line {
                model.invalidate()
                VoiceSample.release(sample)
            }
        }
        .onChange(of: call.lines) { _, lines in
            if let storedLineID, lines.entry(storedLineID)?.line != model.line {
                model.invalidate()
                VoiceSample.release(sample)
            }
        }
        .onChange(of: call.liveVoice) { old, new in
            guard callID != nil, callID == call.liveCallID else { return }
            if let pending = new?.pending, pending != old?.pending {
                announce("\(model.name(pending)) from \(agentName)'s next reply")
            } else if let active = new?.active, new?.pending == nil, old?.pending != nil || old?.active != active {
                announce("\(model.name(active)) configured for this call")
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
                    if let view = model.view {
                        LabeledContent("Saved for next calls", value: view.saved.isEmpty ? "Server default - \(model.name(view.effective))" : model.name(view.effective))
                            .accessibilityIdentifier(AXID.pickerSaved)
                    }
                    if callID != nil, callID == call.liveCallID, let state = call.liveVoice {
                        LabeledContent("This call", value: model.name(state.active)).accessibilityIdentifier(AXID.pickerLive)
                        if let pending = state.pending {
                            LabeledContent("Next spoken line", value: model.name(pending)).accessibilityIdentifier(AXID.pickerNext)
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
                        Picker("Model", selection: Binding(get: { model.draft?.model }, set: model.setModel)) {
                            LabeledContent("Provider default", value: model.provider?.default.model ?? "Unknown")
                                .tag(String?.none)
                            ForEach(model.provider?.models ?? [], id: \.self) { Text($0).tag(Optional($0)) }
                            if let id = draft.model, !(model.provider?.models.contains(id) ?? false) { Text(id).tag(Optional(id)) }
                        }
                        .pickerStyle(.menu).accessibilityIdentifier(AXID.pickerModel)
                        fieldFailure("model")
                        Button {
                            detent = .large
                            path.append("catalog")
                        } label: {
                            LabeledContent("Voice", value: model.selectedVoice?.name ?? "Provider default voice")
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
                Button("Close") { if model.hasChanges { closing = true } else { dismiss() } }
                    .accessibilityIdentifier(AXID.pickerClose)
            }
            ToolbarOverflowMenu {
                Button("Reset saved voice to server default...", role: .destructive) { resetting = true }
                    .disabled(model.invalidated || model.view == nil || model.saving).accessibilityIdentifier(AXID.pickerReset)
            }
        }
        .safeAreaBar(edge: .bottom) { commits }
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
                if let voice = model.selectedVoice { catalogRow(voice) }
                Button { model.setVoice(nil); path.removeLast() } label: {
                    HStack {
                        Text("Provider default voice")
                        Spacer()
                        if model.draft?.voice == nil { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                    }
                }
            }
            Section {
                ForEach(model.voices.filter { $0.id.lowercased() != model.selectedVoice?.id.lowercased() }, id: \.id) { catalogRow($0) }
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
                    Button("All languages") { model.language = "" }
                    ForEach(model.languages, id: \.self) { code in Button(code) { model.language = code } }
                    Button("Enter language code...") { customLanguage = model.language; languagePrompt = true }
                } label: { Label(model.language.isEmpty ? "Language code: All" : "Language code: \(model.language)", systemImage: "line.3.horizontal.decrease") }
            }
        }
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .task(id: "\(model.draft?.provider ?? "")\n\(model.query)\n\(model.language)") { await model.loadCatalog() }
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
                        if let language = voice.language { Text(language).font(.caption).foregroundStyle(.secondary) }
                        if let description = voice.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        if voice.preview == nil { Text("No sample available").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if voice.id.lowercased() == model.draft?.voice?.lowercased() { Image(systemName: "checkmark").accessibilityLabel("Selected") }
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
        requesting = true
        queuedChoice = nil
        liveResult = "Requesting live change..."
        let outcome = await call.requestVoice(draft, for: callID)
        requesting = false
        guard callID == call.liveCallID else { liveResult = "This call has ended. You can still save for next calls."; return }
        switch outcome {
        case .queued:
            queuedChoice = draft
            liveResult = "Queued for the next spoken line. The current spoken line finishes unchanged."
            announce("\(model.name(draft)) from \(agentName)'s next reply")
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
        guard callID == call.liveCallID, let choice = queuedChoice, let state = call.liveVoice else { return }
        let expectedModel = choice.model ?? model.view?.providers.first { $0.id == choice.provider }?.default.model
        let expectedVoice = choice.voice ?? model.view?.providers.first { $0.id == choice.provider }?.default.voice
        if state.pending == nil, state.active.provider == choice.provider,
           state.active.model == expectedModel || state.active.model == choice.model,
           state.active.voice == expectedVoice || state.active.voice == choice.voice {
            liveResult = "Active for this call: \(model.name(state.active))"
            queuedChoice = nil
            announce("\(model.name(state.active)) configured for this call")
        }
    }

    private func announce(_ message: String) {
        guard message != lastAnnouncement else { return }
        lastAnnouncement = message
        var text = AttributedString(message)
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
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

@MainActor
private enum PickerFixture {
    static let scenario = ProcessInfo.processInfo.environment["HEYDAN_PREVIEW_TTS"]
    private static var savedByLine: [URL: [String: Any]] = [:]
    private static let providers = #"[{"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"Alnilam"}},{"id":"elevenlabs","name":"ElevenLabs","available":true,"models":["eleven_turbo_v2_5","eleven_flash_v2_5","eleven_multilingual_v2"],"default":{"model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"}}]"#

    static func response(_ request: URLRequest) throws -> (Int, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        if scenario == "no-route" { return (404, Data()) }
        if scenario == "forbidden", request.httpMethod == "PATCH" || url.path.hasSuffix("voices") { return (403, Data()) }
        if url.path.hasSuffix("voices") {
            if scenario == "catalog-fail" { return (502, Data(#"{"error":"upstream"}"#.utf8)) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let provider = query.first { $0.name == "provider" }?.value ?? "gemini"
            if scenario == "eleven-unavailable", provider == "elevenlabs" { return (503, Data(#"{"error":"provider_unavailable","provider":"elevenlabs"}"#.utf8)) }
            var rows: [[String: Any]]
            if provider == "elevenlabs" {
                rows = [["id": "bIHbv24MWmeRgasZH58o", "name": "Will", "language": "en", "gender": "male", "preview": try sampleURL().absoluteString]]
            } else {
                let data = Data(#"[{"id":"achernar","name":"Achernar","language":"en-US","gender":"female","description":"Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."},{"id":"en-us-techagent-4","name":"Tech Advisor 4","language":"en-US","gender":"male","description":"Tech Support Agent / Tech Advisor. Confident and clear."},{"id":"Alnilam","name":"Alnilam","language":"en-US"}]"#.utf8)
                rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            }
            let search = query.first { $0.name == "q" }?.value ?? ""
            let language = query.first { $0.name == "language" }?.value
            rows = rows.filter { row in
                (search.isEmpty || "\(row["name"] ?? "") \(row["description"] ?? "")".localizedCaseInsensitiveContains(search)) && (language == nil || row["language"] as? String == language)
            }
            if scenario == "search-empty" { rows = [] }
            var page: [String: Any] = ["provider": provider, "voices": rows]
            if provider == "gemini", !rows.isEmpty, !query.contains(where: { $0.name == "cursor" }) { page["next"] = "eyJvIjoxMDB9" }
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/voice/tts"
        let key = components.url!
        var saved = savedByLine[key] ?? (scenario == "unsaved" ? [:] : ["provider": "gemini", "voice": "en-us-techagent-4"])
        let providerRows = try JSONSerialization.jsonObject(with: Data(providers.utf8)) as! [[String: Any]]
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
            if input["reset"] as? Bool == true { saved = [:] } else {
                guard let id = input["provider"] as? String, let provider = available.first(where: { $0["id"] as? String == id }) else { return (400, Data(#"{"error":"invalid","field":"provider"}"#.utf8)) }
                guard provider["available"] as? Bool == true else { return (503, Data(#"{"error":"provider_unavailable","provider":"elevenlabs"}"#.utf8)) }
                saved = input
            }
            savedByLine[key] = saved
        }
        let provider = available.first { $0["id"] as? String == saved["provider"] as? String } ?? available[0]
        let defaults = provider["default"] as! [String: Any]
        let effective: [String: Any] = ["provider": saved["provider"] ?? provider["id"]!, "model": saved["model"] ?? defaults["model"]!, "voice": saved["voice"] ?? defaults["voice"]!]
        return (200, try JSONSerialization.data(withJSONObject: ["effective": effective, "saved": saved, "providers": available]))
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
