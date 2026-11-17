import AppIntents

/// H6 owns paired-agent discovery for intents.
struct PairedAgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Paired agent")
    static let defaultQuery = Query()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    struct Query: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [PairedAgentEntity] { [] }
        func suggestedEntities() async throws -> [PairedAgentEntity] { [] }
    }
}
