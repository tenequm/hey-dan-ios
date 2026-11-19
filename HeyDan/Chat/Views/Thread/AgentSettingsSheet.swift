import SwiftUI
import HeyDanCore

struct ContextRing: View {
    @Environment(\.theme) private var theme
    let session: AgentStatus.Session

    var body: some View {
        ZStack {
            Circle().stroke(theme.color.composerBorder, lineWidth: 3)
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
    let working: Bool
    let statusFailure: String?
    let save: (AgentSettingsRequest) async throws(AppError) -> Void
    let compact: () async -> Bool
    @State private var modelChoice: String?
    @State private var effortChoice: String?
    @State private var confirming = false
    @State private var submitting = false
    @State private var errorMessage: String?

    private var model: String? { modelChoice ?? status.agent.model.id }
    private var effort: String? { effortChoice ?? status.agent.effort }
    private var change: AgentSettingsRequest {
        .init(model: model == status.agent.model.id ? nil : model,
              effort: effort == status.agent.effort ? nil : effort)
    }
    private var changed: Bool { change.model != nil || change.effort != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    option(status.agent.inheritedLabel, selected: model == nil) { modelChoice = nil }
                        // The host accepts model ids but has no write to clear a pinned model.
                        .disabled(status.agent.model.id != nil)
                    if let current = status.agent.model.id, !status.options.models.contains(where: { $0.id == current }) {
                        option(status.agent.model.displayName, selected: model == current) { modelChoice = current }
                    }
                    ForEach(status.options.models.filter { $0.id != nil }, id: \.id) { item in
                        option(item.displayName, selected: model == item.id) { modelChoice = item.id }
                    }
                }
                Section("Effort") {
                    ForEach(status.options.efforts, id: \.self) { level in
                        option(level.capitalized, selected: effort == level) { effortChoice = level }
                    }
                }
                if let description = status.session.usageDescription() {
                    Section("Context") {
                        HStack {
                            ContextRing(session: status.session)
                            Text(description)
                        }
                        if let fraction = status.session.usageFraction {
                            ProgressView(value: min(1, fraction))
                                .tint(fraction >= 0.8 ? theme.color.warning : theme.color.accentText)
                                .accessibilityLabel("Context used")
                        }
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
                        if working { confirming = true } else { submit() }
                    }
                }
            }
            .disabled(submitting)
            .interactiveDismissDisabled(submitting)
            .alert("Changing the model stops the current reply.", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Save", role: .destructive) { submit() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(theme.color.textPrimary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(theme.color.accentText) }
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
