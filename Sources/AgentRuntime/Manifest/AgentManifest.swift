import Foundation

/// Errors raised while loading a portable manifest, before any session exists.
public enum AgentManifestError: Error, Equatable, Sendable {
    /// The data is not a JSON object document.
    case notAJSONObject
    /// The document has no `schema_version` member.
    case missingSchemaVersion
    /// The document declares a `schema_version` this runtime cannot execute.
    case unsupportedSchemaVersion(found: String, supported: Set<String>)
    /// The document failed typed decoding against the AgentConfig contract.
    case invalidManifest(String)
}

/// A loaded portable manifest: the typed `AgentConfig` view plus the complete
/// raw document, so unknown or pass-through sections survive round-trips.
public struct AgentManifest: Equatable, Sendable {
    /// Typed view of the manifest.
    public let config: AgentConfig
    /// The full raw JSON document, including members this runtime does not model.
    public let document: JSONValue

    /// Re-encodes the complete original document (unknown members included)
    /// with deterministic key ordering.
    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
}

/// Loads and validates portable `AgentConfig` manifests from local data.
///
/// Loading is purely local: no network access of any kind, and no
/// AgentFactory control-plane dependency.
public enum AgentManifestLoader {
    /// Loads a manifest from raw JSON data.
    public static func load(_ data: Data) throws -> AgentManifest {
        let document: JSONValue
        do {
            document = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AgentManifestError.invalidManifest("Document is not valid JSON: \(error)")
        }
        guard case .object = document else {
            throw AgentManifestError.notAJSONObject
        }

        // Gate on schema_version before full decoding so a future-schema
        // manifest reports version mismatch rather than a field-level error.
        guard let versionMember = document["schema_version"] else {
            throw AgentManifestError.missingSchemaVersion
        }
        guard let schemaVersion = versionMember.stringValue,
              SupportedSchemaVersion.all.contains(schemaVersion) else {
            let found = versionMember.stringValue ?? String(describing: versionMember)
            throw AgentManifestError.unsupportedSchemaVersion(found: found, supported: SupportedSchemaVersion.all)
        }

        let config: AgentConfig
        do {
            config = try JSONDecoder().decode(AgentConfig.self, from: data)
        } catch let error as DecodingError {
            throw AgentManifestError.invalidManifest(Self.describe(error))
        } catch {
            throw AgentManifestError.invalidManifest(String(describing: error))
        }
        return AgentManifest(config: config, document: document)
    }

    /// Loads a manifest from a local file URL (for example, a bundle resource).
    public static func load(contentsOf url: URL) throws -> AgentManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentManifestError.invalidManifest("Unreadable manifest at \(url.path): \(error)")
        }
        return try load(data)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return "Missing required member: \(path)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Wrong type at \(path): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "Corrupt manifest: \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
