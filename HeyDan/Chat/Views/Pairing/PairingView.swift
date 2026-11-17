import SwiftUI

struct PairingView: View {
    @State private var link = ""
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("Pair with your host") {
                TextField("Pairing link", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("pairing.link")
                PasteButton(payloadType: String.self) { @Sendable strings in
                    Task { @MainActor in link = strings.first ?? "" }
                }
                .accessibilityIdentifier("pairing.paste")
                Button("Pair") {
                    working = true
                    message = nil
                    Task {
                        defer { working = false }
                        do {
                            try await Pairings.shared.pair(link)
                            link = ""
                            message = "Paired"
                        } catch let error as AppError { message = error.message }
                        catch { message = error.localizedDescription }
                    }
                }
                .disabled(working || link.isEmpty)
                .accessibilityIdentifier("pairing.submit")
                if working { ProgressView() }
                if let message = message ?? Pairings.shared.error?.message { Text(message).accessibilityIdentifier("pairing.message") }
            }
        }
        .navigationTitle("Pair device")
        .task { _ = Pairings.shared }
    }
}
