import Foundation

/// Validates the known Messages SSE lifecycle while retaining unknown blocks
/// for forward-compatible replay. No provider text enters diagnostics.
struct AnthropicStreamAccumulator {
    private struct Block {
        var value: [String: JSONValue]
        var partialJSON = ""
        var closed = false
    }
    private var started = false
    private var blocks: [Int: Block] = [:]
    private(set) var isComplete = false
    private(set) var stopReason: String?

    var content: [AnthropicWire.ContentBlock] {
        blocks.keys.sorted().compactMap { index in
            guard let value = blocks[index]?.value else { return nil }
            if value["type"]?.stringValue == "text" {
                return .text(value["text"]?.stringValue ?? "")
            }
            if value["type"]?.stringValue == "tool_use", case .object(let input)? = value["input"] {
                return .toolUse(id: value["id"]?.stringValue ?? "", name: value["name"]?.stringValue ?? "", input: input)
            }
            return .opaque(.object(value))
        }
    }

    var text: String {
        content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
    }

    private static let knownEvents: Set<String> = [
        "message_start", "content_block_start", "content_block_delta", "content_block_stop",
        "message_delta", "message_stop", "error", "ping"
    ]
    private var invalid: AgentRuntimeError { .invalidProviderResponse("Malformed Messages API stream") }

    /// Returns a text delta for immediate publication, if one was received.
    mutating func consume(_ event: ServerSentEvent) throws -> String? {
        // Unknown named events may introduce a new payload shape.
        if let name = event.event, !Self.knownEvents.contains(name) { return nil }
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = payload, let type = payload["type"]?.stringValue else { throw invalid }
        guard event.event == nil || event.event == type else { throw invalid }
        guard Self.knownEvents.contains(type) else { return nil }
        if type == "ping" { return nil }
        guard !isComplete else { throw invalid }
        if type == "error" {
            guard case .object(let error)? = payload["error"],
                  let errorType = error["type"]?.stringValue else { throw invalid }
            throw ClaudeMessagesSession.mapStreamError(type: errorType, message: error["message"]?.stringValue)
        }
        if type == "message_start" {
            guard !started, case .object? = payload["message"] else { throw invalid }
            started = true
            return nil
        }
        guard started else { throw invalid }
        if type == "message_delta" {
            guard blocks.values.allSatisfy(\.closed), case .object(let delta)? = payload["delta"] else { throw invalid }
            if let reason = delta["stop_reason"] {
                switch reason {
                case .null: break
                case .string(let value) where !value.isEmpty: stopReason = value
                default: throw invalid
                }
            }
            return nil
        }
        if type == "message_stop" {
            guard blocks.values.allSatisfy(\.closed), stopReason != nil else { throw invalid }
            isComplete = true
            return nil
        }
        guard stopReason == nil, case .integer(let index)? = payload["index"], index >= 0 else { throw invalid }
        if type == "content_block_start" {
            guard blocks[index] == nil, case .object(let value)? = payload["content_block"],
                  let blockType = value["type"]?.stringValue, !blockType.isEmpty else { throw invalid }
            switch blockType {
            case "text":
                guard let text = value["text"]?.stringValue else { throw invalid }
                blocks[index] = Block(value: value)
                return text.isEmpty ? nil : text
            case "tool_use":
                guard let id = value["id"]?.stringValue, !id.isEmpty,
                      let name = value["name"]?.stringValue, !name.isEmpty,
                      case .object? = value["input"] else { throw invalid }
            default: break
            }
            blocks[index] = Block(value: value)
            return nil
        }
        guard var block = blocks[index], !block.closed else { throw invalid }
        if type == "content_block_stop" {
            if block.value["type"]?.stringValue == "tool_use", !block.partialJSON.isEmpty {
                guard let data = block.partialJSON.data(using: .utf8),
                      let input = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .object = input else { throw invalid }
                block.value["input"] = input
            }
            block.closed = true
            blocks[index] = block
            return nil
        }
        guard type == "content_block_delta", case .object(let delta)? = payload["delta"],
              let deltaType = delta["type"]?.stringValue else { throw invalid }
        var chunk: String?
        switch deltaType {
        case "text_delta":
            guard block.value["type"]?.stringValue == "text", let text = delta["text"]?.stringValue else { throw invalid }
            block.value["text"] = .string((block.value["text"]?.stringValue ?? "") + text)
            chunk = text.isEmpty ? nil : text
        case "input_json_delta":
            guard block.value["type"]?.stringValue == "tool_use", let json = delta["partial_json"]?.stringValue,
                  case .object(let initial)? = block.value["input"], initial.isEmpty else { throw invalid }
            block.partialJSON += json
        case "thinking_delta", "signature_delta":
            guard block.value["type"]?.stringValue == "thinking" else { throw invalid }
            let key = deltaType == "thinking_delta" ? "thinking" : "signature"
            guard let value = delta[key]?.stringValue else { throw invalid }
            block.value[key] = .string((block.value[key]?.stringValue ?? "") + value)
        default: break
        }
        blocks[index] = block
        return chunk
    }
}
