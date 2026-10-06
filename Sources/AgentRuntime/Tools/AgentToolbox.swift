import Foundation

/// The normalized tool surface for a manifest.
///
/// Normalization matches the control-plane sidecar
/// (`LangchainAdaptorService/app/application/tools_manager.py`):
/// - an explicit `allowed` list wins, even when empty;
/// - `allowed` absent with definitions present exposes every defined name;
/// - no `tools` section, or `allowed: []`, exposes zero tools;
/// - `allowed` entries with no matching definition are ignored;
/// - duplicate names resolve to their last definition.
///
/// Names use exact Unicode spelling and Unicode scalar sort order, matching
/// Python's string equality and ordering in the sidecar.
public struct AgentToolbox: Sendable, Equatable {
    /// Tools the model may see and call, sorted by name in sidecar order.
    public let tools: [ToolDefinition]
    /// The manifest's tool policy, passed through for enforcement.
    public let policy: AgentToolPolicy?
    /// `runtime.max_concurrent_tools` from the manifest.
    public let maxConcurrentTools: Int?

    public var isEmpty: Bool { tools.isEmpty }

    public func definition(named name: String) -> ToolDefinition? {
        tools.first { $0.name.utf8.elementsEqual(name.utf8) }
    }

    /// Builds the normalized toolbox for a manifest. An agent with no tools
    /// configured always yields an empty toolbox — no hidden built-in tools.
    public static func resolve(config: AgentConfig) -> AgentToolbox {
        let toolsConfig = config.tools
        let definitions = toolsConfig?.definitions ?? []

        // Swift String equality folds canonically equivalent spellings;
        // Python does not. UTF-8 keys preserve exact names, and their lexical
        // order matches Unicode scalar order for valid strings.
        var byName: [Data: ToolDefinition] = [:]
        for definition in definitions {
            byName[Data(definition.name.utf8)] = definition
        }
        let allowedNames = toolsConfig?.allowed.map { Set($0.map { Data($0.utf8) }) }
            ?? Set(byName.keys)
        let ordered = allowedNames.sorted { $0.lexicographicallyPrecedes($1) }
            .compactMap { byName[$0] }

        return AgentToolbox(
            tools: ordered,
            policy: toolsConfig?.toolPolicy,
            maxConcurrentTools: config.runtime.maxConcurrentTools
        )
    }
}
