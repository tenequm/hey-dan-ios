import SwiftUI
import HeyDanCore

struct ContextRing: View {
    @Environment(\.theme) private var theme
    let session: AgentStatus.Session

    var body: some View {
        ZStack {
            Circle().stroke(theme.color.textSecondary.opacity(0.35), lineWidth: 3)
            if let usage = session.usageFraction {
                Circle().trim(from: 0, to: min(1, usage))
                    .stroke(usage >= 0.8 ? theme.color.warning : theme.color.accentText,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

struct AgentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let status: AgentStatus
    let editable: Bool
    let statusFailure: String?
    let save: (AgentSettingsRequest) async throws(AppError) -> Void
    let compact: () async -> Bool
    @State private var modelChoice: AgentSettingsRequest.Field?
    @State private var effortChoice: AgentSettingsRequest.Field?
    @State private var confirming = false
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var detent: PresentationDetent = .large

    private var model: AgentSettingsRequest.Field { modelChoice ?? .init(status.agent.model.id) }
    private var effort: AgentSettingsRequest.Field { effortChoice ?? .init(status.agent.effort) }
    private var change: AgentSettingsRequest {
        .init(model: model == .init(status.agent.model.id) ? nil : model,
              effort: effort == .init(status.agent.effort) ? nil : effort)
    }
    private var changed: Bool { change.model != nil || change.effort != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    option(status.agent.inheritedLabel, selected: model == .inherited) { modelChoice = .inherited }
                    if let current = status.agent.model.id, !status.options.models.contains(where: { $0.id == current }) {
                        option(status.agent.model.displayName, selected: model == .value(current)) { modelChoice = .value(current) }
                    }
                    ForEach(status.options.models.filter { $0.id != nil }, id: \.id) { item in
                        option(item.displayName, selected: model == .init(item.id)) { modelChoice = .init(item.id) }
                    }
                }
                Section("Effort") {
                    ForEach(status.options.efforts, id: \.self) { level in
                        option(AgentStatus.effortName(level), selected: effort == .value(level)
                            || (effort == .inherited && level == status.agent.defaultEffort)) { effortChoice = .value(level) }
                    }
                }
                if let description = status.session.usageDescription() {
                    Section("Context") {
                        HStack {
                            ContextRing(session: status.session)
                            Text(description)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(status.session.usageDescription(spoken: true) ?? description)
                        if let fraction = status.session.usageFraction {
                            ProgressView(value: min(1, fraction))
                                .tint(fraction >= 0.8 ? theme.color.warning : theme.color.accentText)
                                .accessibilityHidden(true)
                        }
                        if status.agent.canEdit {
                            Button("Compact now") {
                                submitting = true
                                Task {
                                    if await compact() { dismiss() }
                                    else { errorMessage = "Could not queue /compact. Try again." }
                                    submitting = false
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = errorMessage ?? statusFailure {
                    Text(message)
                        .foregroundStyle(theme.color.danger)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .navigationTitle(status.agent.name)
            .navigationSubtitle("Applies in every chat with " + status.agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(changed && editable ? "Save" : "Done") {
                        guard changed, editable else { dismiss(); return }
                        confirming = true
                    }
                }
            }
            .disabled(submitting)
            .interactiveDismissDisabled(submitting)
            .alert("Changes \(status.agent.name) in every chat. A reply in progress stops.", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Save", role: .destructive) { submit() }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(theme.color.textPrimary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(theme.color.accentText).accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .disabled(!editable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() {
        guard editable, changed, !submitting else { return }
        let request = change
        errorMessage = nil
        submitting = true
        Task {
            do { try await save(request); dismiss() }
            catch { errorMessage = AppError.map(error).message }
            submitting = false
        }
    }
}
