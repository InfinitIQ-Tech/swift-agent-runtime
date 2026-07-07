import Foundation

/// The normalized tool surface for a manifest.
///
/// Normalization matches the control-plane sidecar
/// (`LangchainAdaptorService/app/application/tools_manager.py`):
/// - an explicit `allowed` list wins, even when empty;
/// - `allowed` absent with definitions present exposes every definition;
/// - no `tools` section, or `allowed: []`, exposes zero tools;
/// - `allowed` entries with no matching definition are ignored.
///
/// Exposure order follows the manifest (`allowed` order when declared,
/// otherwise `definitions` order); the exposed *set* is sidecar-identical.
public struct AgentToolbox: Sendable, Equatable {
    /// Tools the model may see and call, in manifest order.
    public let tools: [ToolDefinition]
    /// The manifest's tool policy, passed through for enforcement.
    public let policy: AgentToolPolicy?
    /// `runtime.max_concurrent_tools` from the manifest.
    public let maxConcurrentTools: Int?

    public var isEmpty: Bool { tools.isEmpty }

    public func definition(named name: String) -> ToolDefinition? {
        tools.first { $0.name == name }
    }

    /// Builds the normalized toolbox for a manifest. An agent with no tools
    /// configured always yields an empty toolbox — no hidden built-in tools.
    public static func resolve(config: AgentConfig) -> AgentToolbox {
        let toolsConfig = config.tools
        let definitions = toolsConfig?.definitions ?? []

        let allowedNames: Set<String>
        if let allowed = toolsConfig?.allowed {
            allowedNames = Set(allowed)
        } else {
            allowedNames = Set(definitions.map(\.name))
        }

        let ordered: [ToolDefinition]
        if let allowed = toolsConfig?.allowed {
            var byName: [String: ToolDefinition] = [:]
            for definition in definitions { byName[definition.name] = definition }
            var seen = Set<String>()
            ordered = allowed.compactMap { name in
                guard seen.insert(name).inserted else { return nil }
                return byName[name]
            }
        } else {
            ordered = definitions.filter { allowedNames.contains($0.name) }
        }

        return AgentToolbox(
            tools: ordered,
            policy: toolsConfig?.toolPolicy,
            maxConcurrentTools: config.runtime.maxConcurrentTools
        )
    }
}
