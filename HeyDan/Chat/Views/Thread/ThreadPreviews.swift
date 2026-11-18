#if DEBUG
import SwiftUI
import HeyDanCore

private enum ThreadPreviewValues {
    static func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
    static let agentMarkdown0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[],"voice":null,"replyTo":null,"clientId":null,"delivery":null,"deliveryError":null,"editedAt":null,"seq":2101,"order":2101,"createdAt":1794943662000,"id":"msg_2101","role":"agent","text":"## Result\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```sh\necho \"$HOME\"\n```"}"####)
    static let agentWithFiles0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[{"id":"file_img01","name":"chart.png","mimeType":"image/png","size":48211,"kind":"image","width":1200,"height":800},{"id":"file_doc01","name":"report.pdf","mimeType":"application/pdf","size":301442,"kind":"file","width":null,"height":null}],"reactions":[],"voice":null,"replyTo":null,"clientId":null,"delivery":null,"deliveryError":null,"editedAt":null,"seq":2102,"order":2102,"createdAt":1794943662000,"id":"msg_2102","role":"agent","text":"Done. The report is attached."}"####)
    static let userWithFile0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[{"id":"file_7hT2pQ9a","name":"notes.txt","mimeType":"text/plain","size":33,"kind":"file","width":null,"height":null}],"reactions":[],"voice":null,"replyTo":null,"clientId":"5d2c8e0a-61b4-4f0e-8c43-1f7a9e2b6d30","delivery":"reached","deliveryError":null,"editedAt":null,"seq":2104,"order":2103,"createdAt":1794943662000,"id":"msg_2103","role":"user","text":"Here is the log."}"####)
    static let userUnknown0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[],"voice":null,"replyTo":null,"clientId":"9a1f3c7e-2b4d-4e8a-b6c0-7d5e1f9a3b2c","delivery":"unknown","deliveryError":{"error":"outcome_unknown","message":"The host restarted while sending this, so it may or may not have reached the agent. Check before you send it again."},"editedAt":null,"seq":2106,"order":2105,"createdAt":1794943662000,"id":"msg_2105","role":"user","text":"are you there?"}"####)
    static let userFailed0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[],"voice":null,"replyTo":null,"clientId":"3e4f5a6b-7c8d-4e9f-a0b1-c2d3e4f5a6b7","delivery":"failed","deliveryError":{"error":"not_routed","message":"This message did not reach the agent. You can send it again."},"editedAt":null,"seq":2114,"order":2113,"createdAt":1794943662000,"id":"msg_2113","role":"user","text":"hello?"}"####)
    static let voiceCaller0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[],"voice":"caller","replyTo":null,"clientId":null,"delivery":null,"deliveryError":null,"editedAt":null,"seq":2107,"order":2107,"createdAt":1794943662000,"id":"msg_2107","role":"user","text":"What is two plus two?"}"####)
    static let voiceSpoken0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[],"voice":"spoken","replyTo":null,"clientId":null,"delivery":null,"deliveryError":null,"editedAt":null,"seq":2108,"order":2108,"createdAt":1794943662000,"id":"msg_2108","role":"agent","text":"Four."}"####)
    static let host0: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[],"voice":null,"replyTo":null,"clientId":null,"delivery":null,"deliveryError":null,"editedAt":null,"seq":2109,"order":2109,"createdAt":1794943662000,"id":"msg_2109","role":"host","text":"Context cleared."}"####)
    static let editSequence2: Message = decode(####"{"kind":"message","conversationId":"conv_taylor01","files":[],"reactions":[{"emoji":"👍","by":"agent"}],"voice":null,"replyTo":null,"clientId":null,"delivery":null,"deliveryError":null,"editedAt":1794943593000,"id":"msg_0126","order":126,"seq":128,"role":"agent","text":"Second draft.","createdAt":1794943592000}"####)
    static let questionopen: Question = decode(####"{"kind":"question","id":"q_0123","conversationId":"conv_taylor01","order":123,"seq":123,"title":"Deploy","text":"Deploy to which environment?","options":[{"label":"Staging","selectedLabel":"Staging","value":"staging","style":"primary"},{"label":"Production","selectedLabel":"Production","value":"production","style":"danger"},{"label":"Cancel","selectedLabel":"Cancelled","value":"cancel","style":null}],"state":"open","answer":null,"createdAt":1794943574000,"expiresAt":1794943874000}"####)
    static let questionanswered: Question = decode(####"{"kind":"question","id":"q_0123","conversationId":"conv_taylor01","order":123,"seq":125,"title":"Deploy","text":"Deploy to which environment?","options":[{"label":"Staging","selectedLabel":"Staging","value":"staging","style":"primary"},{"label":"Production","selectedLabel":"Production","value":"production","style":"danger"},{"label":"Cancel","selectedLabel":"Cancelled","value":"cancel","style":null}],"state":"answered","answer":{"value":"staging","label":"Staging","at":1794943587000},"createdAt":1794943574000,"expiresAt":1794943874000}"####)
    static let questionexpired: Question = decode(####"{"kind":"question","id":"q_2110","conversationId":"conv_taylor01","order":2110,"seq":2111,"title":"Deploy","text":"Deploy to which environment?","options":[{"label":"Staging","selectedLabel":"Staging","value":"staging","style":"primary"},{"label":"Production","selectedLabel":"Production","value":"production","style":"danger"},{"label":"Cancel","selectedLabel":"Cancelled","value":"cancel","style":null}],"state":"expired","answer":null,"createdAt":1794943574000,"expiresAt":1794943662000}"####)
    static let statusworking: Status = decode(####"{"kind":"status","conversationId":"conv_taylor01","rev":41,"state":"working","label":"Running a command","at":1794943595000}"####)
    static let statuswaiting: Status = decode(####"{"kind":"status","conversationId":"conv_taylor01","rev":40,"state":"waiting","label":"Waiting for your answer","at":1794943574000}"####)
    static let conversation: Conversation = decode(####"{"kind":"conversation","id":"conv_taylor01","seq":129,"agent":{"id":"ag_taylor","name":"Taylor"},"lastMessage":{"id":"msg_0126","role":"agent","preview":"Second draft.","at":1794943593000},"unread":3,"readOrder":118,"canCall":true,"callRefusal":null,"createdAt":1794857162000}"####)
}
#Preview("agentMarkdown0") { MessageRow(message: ThreadPreviewValues.agentMarkdown0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("agentWithFiles0") { MessageRow(message: ThreadPreviewValues.agentWithFiles0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("userWithFile0") { MessageRow(message: ThreadPreviewValues.userWithFile0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("userUnknown0") { MessageRow(message: ThreadPreviewValues.userUnknown0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("userFailed0") { MessageRow(message: ThreadPreviewValues.userFailed0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("voiceCaller0") { MessageRow(message: ThreadPreviewValues.voiceCaller0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("voiceSpoken0") { MessageRow(message: ThreadPreviewValues.voiceSpoken0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("host0") { MessageRow(message: ThreadPreviewValues.host0).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("editSequence2") { MessageRow(message: ThreadPreviewValues.editSequence2).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2) }
#Preview("Question open") { QuestionCard(question: ThreadPreviewValues.questionopen).preferredColorScheme(.dark) }
#Preview("Question answered") { QuestionCard(question: ThreadPreviewValues.questionanswered).preferredColorScheme(.dark) }
#Preview("Question expired") { QuestionCard(question: ThreadPreviewValues.questionexpired).preferredColorScheme(.dark) }
#Preview("Status working") { StatusPill(status: ThreadPreviewValues.statusworking) }
#Preview("Status waiting") { StatusPill(status: ThreadPreviewValues.statuswaiting) }
#Preview("Conversation unread") { ConversationRow(conversation: ThreadPreviewValues.conversation) }
#Preview("Conversation read") {
    var conversation = ThreadPreviewValues.conversation
    conversation.unread = 0
    return ConversationRow(conversation: conversation)
}
#Preview("Answer delivery error") {
    QuestionCard(question: ThreadPreviewValues.questionopen, errorMessage: "The answer did not reach the agent. Try again.")
}
#Preview("200 messages") {
    ThreadContent(rows: (0..<200).map { index in
        var message = ThreadPreviewValues.agentMarkdown0
        message.id = "preview-\(index)"
        message.order = Int64(index)
        return .entity(.message(message))
    }).preferredColorScheme(.dark).dynamicTypeSize(...DynamicTypeSize.accessibility2)
}
#Preview("Outbox states") {
    ScrollView {
        VStack {
            ForEach(Array([Outbox.State.queued, .waiting, .held, .stored, .routed, .reached, .failed, .outcomeUnknown].enumerated()), id: \.offset) { _, state in
                MessageRow(message: ThreadPreviewValues.userWithFile0, outboxState: state)
            }
        }
    }.preferredColorScheme(.dark)
}
#endif
