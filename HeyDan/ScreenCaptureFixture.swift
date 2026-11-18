#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import HeyDanCore

/// The capture runner writes the next fixture atomically. Remounting the view clears sheets,
/// navigation and drafts without relaunching the app or adding controls to the screenshot.
struct ScreenCaptureFixture: View {
    let requestURL: URL
    @State private var request: Request?
    static var phase: String?

    private struct Request: Decodable {
        let id: String
        let family: String
        let scenario: String?
        let phase: String?
    }

    var body: some View {
        ZStack {
            if let request {
                screen(request)
                    .onAppear {
                        try? Data(request.id.utf8).write(to: requestURL.appendingPathExtension("ready"), options: .atomic)
                    }
                    .id(request.id)
            }
        }
        .task {
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: requestURL),
                   let next = try? JSONDecoder().decode(Request.self, from: data), next.id != request?.id {
                    Self.phase = next.phase
                    if next.family == "chat" {
                        ChatController.shared.selectCaptureFixture(next.scenario, id: next.id)
                    }
                    request = next
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    @ViewBuilder private func screen(_ request: Request) -> some View {
        switch request.family {
        case "chat": ConversationList()
        case "list": ConversationListSpecimen(name: "List/" + (request.scenario ?? "Activity"))
        case "pairing": PairingView()
        case "paired": PairingView(paired: Pairings.shared.active)
        case "lines": NavigationStack { VoiceLinesSettings() }
        case "call":
            let target = PairedCallTarget(host: FixtureAppService.host, deviceId: FixtureAppService.pairing.deviceId,
                                          conversation: FixtureContent.conversation)
            PairedCallCover(target: CallTarget(paired: target, service: FixtureAppService()))
        default: EmptyView()
        }
    }
}
#endif
