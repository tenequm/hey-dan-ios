#if DEBUG
import Foundation
import HeyDanCore

enum FixtureContent {
    static let capturing = ProcessInfo.processInfo.environment["HEYDAN_CAPTURE_REQUEST"] != nil
    static let host = URL(string: "https://home.example.ts.net")!
    static let agents = [Agent(id: "ag_dan", name: "Dan"), Agent(id: "ag_stan", name: "Stan")]
    static let conversation = Conversation(kind: .conversation, id: "conv_dan", seq: 1, agent: agents[0],
                                          unread: 0, readOrder: 0, canCall: true, createdAt: 0)
    static let question = Question(kind: .question, id: "q_snapshot", conversationId: conversation.id,
        order: 8, seq: 8, title: "Which snapshot should I restore?",
        text: "Last night's run stopped at 61%; yesterday's 02:00 run is the last complete one (1.2 TB).",
        options: [
            .init(label: "Last night, 02:00", selectedLabel: "Restore last night's 02:00 snapshot", value: "last", style: nil),
            .init(label: "Yesterday, 02:00", selectedLabel: "Restore yesterday's 02:00 snapshot", value: "complete", style: "primary"),
            .init(label: "Don't restore", selectedLabel: "Don't restore", value: "cancel", style: nil)
        ], state: .open, createdAt: 0)
    static let caller = "Did the backup run again?"
    static let reply = "The key is rotated and the backup is running again. It should finish in about forty minutes."
    static let notification = "Backup is green again. The backup log is attached."
    static let full = "## Nightly backup failed\n\nThe storage key expired at 02:00, so the backup job could not open the repository. Nothing was lost: yesterday's snapshot is intact.\n\n- Rotated the storage key\n- Re-ran backup-job.service (61% done)\n\n```bash\n# rotate the key, then re-run\nsecrets rotate backup/storage-key\nsystemctl --user start backup-job\njournalctl -u backup-job -n 20\n```"

    static func messages(_ scenario: String?, card: Message) -> [Message] {
        func row(_ order: Int64, _ role: Role, _ text: String, voice: Voice? = nil) -> Message {
            Message(kind: .message, id: "msg_\(order)", conversationId: conversation.id, order: order, seq: order,
                    role: role, text: text, files: [], reactions: [], voice: voice, createdAt: 1794994860000 + order * 60000)
        }
        switch scenario {
        case "summary", "table":
            var report = card
            report.conversationId = conversation.id
            return [row(2, .agent, "The re-run finished. Summary:"), report]
        case "attachments":
            var file = row(3, .agent, "Same error, just surfaced later by the NAS check. Here is the full log from last night's run:")
            file.files = [.init(id: "file_backup", name: "backup-job.log", mimeType: "text/plain", size: 49152, kind: .file)]
            var image = row(2, .user, "The NAS showed this at 7. Same thing?")
            image.files = [.init(id: "file_img01", name: "nas.png", mimeType: "image/png", size: 79505, kind: .image, width: 240, height: 180)]
            return [image, file]
        case "spoken":
            return [row(2, .user, "Did the backup finish? And is Stan's line still flaky?", voice: .caller),
                    row(3, .agent, "It finished at 9:41, all green. Stan's line was fine on the last three test calls; the flaky one was before the TURN fix.", voice: .spoken),
                    row(4, .user, "Great. Send me the log here.", voice: .caller), row(5, .agent, "Sent below.")]
        case "failed":
            var failed = row(4, .user, "Also tell Stan the key is rotated.")
            failed.clientId = "capture-failed"
            failed.delivery = .failed
            failed.deliveryError = ErrorBody(error: "not_routed", message: "Not delivered")
            return [row(2, .agent, "Done. The backup is green again: 1.2 TB in 48 minutes."),
                    row(3, .user, "Thanks. Can you move it to 01:30 from now on?"), failed]
        case "history":
            return [row(2, .user, "Remind me to renew the storage key before it expires."),
                    row(3, .agent, "Noted. It expires tonight at 02:00, so I'll rotate it first thing if you don't. Want me to do it now instead?"),
                    row(4, .user, "Tomorrow is fine."), row(5, .agent, "Okay. I'll remind you at 08:00.")]
        case "question":
            return [row(2, .user, "Why did the nightly backup fail? Can you fix it before tonight?"),
                    row(3, .agent, "The storage key expired at 02:00. I rotated it. Before I re-run: one question.")]
        case "full":
            var photo = messages("attachments", card: card)
            for index in photo.indices {
                photo[index].order += 2
                photo[index].seq = photo[index].order
                photo[index].id = "msg_\(photo[index].order)"
            }
            var report = card
            report.order = 7
            report.seq = 7
            report.conversationId = conversation.id
            return [row(2, .user, "Why did the nightly backup fail? Can you fix it before tonight?"), row(3, .agent, full)]
                + photo + [row(6, .agent, "The re-run finished. Summary:"), report]
        default:
            return [row(2, .agent, "Backup is green again. Anything else for tonight?")]
        }
    }

    static let voices = [VoiceLineCatalogVoice(id: "aria", name: "Aria", language: "en", description: "Warm, steady"),
                         VoiceLineCatalogVoice(id: "roger", name: "Roger", language: "en", description: "Calm, low"),
                         VoiceLineCatalogVoice(id: "sarah", name: "Sarah", language: "en", description: "Bright, quick")]
    static let voice: TTSView = {
        let details = ChoiceDetails(provider: "elevenlabs", providerName: "ElevenLabs", model: "eleven_v4", modelName: "Eleven v4",
                                    voice: "aria", voiceName: "Aria", language: "en", status: .resolved)
        let providers = [("elevenlabs", "ElevenLabs", true), ("openai", "OpenAI", true), ("cartesia", "Cartesia", false)]
        return TTSView(effective: .init(provider: "elevenlabs", model: "eleven_v4", voice: "aria"),
                       saved: .init(provider: "elevenlabs", model: "eleven_v4", voice: "aria"),
                       providers: providers.map { .init(id: $0.0, name: $0.1, available: $0.2, models: $0.0 == "elevenlabs" ? ["eleven_v4"] : [],
                                                      default: .init(model: $0.0 == "elevenlabs" ? "eleven_v4" : "", voice: $0.0 == "elevenlabs" ? "aria" : "")) },
                       details: .init(saved: details, effective: details))
    }()
}
#endif
