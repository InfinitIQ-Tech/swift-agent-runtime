import Darwin
import Foundation

/// Runtime-authored diagnostics; never includes terminal input.
enum SecureKeyReaderError: Error, CustomStringConvertible {
    case terminalUnavailable
    case inputTooLong
    case invalidEncoding

    var description: String {
        switch self {
        case .terminalUnavailable: "secure key entry requires an interactive terminal"
        case .inputTooLong: "provider key input exceeds the supported length"
        case .invalidEncoding: "provider key input is not valid UTF-8"
        }
    }
}

/// Reads up to 1022 UTF-8 bytes without echo or stdin fallback. Darwin's
/// canonical terminal input limit is 1024 bytes; keep this buffer within that
/// limit and reject a full result before terminal/reader truncation can pass
/// unnoticed. readpassphrase itself silently discards overflow.
func readSecureProviderKey() throws -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer {
        buffer.withUnsafeMutableBytes { bytes in
            _ = memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
        }
    }
    return try buffer.withUnsafeMutableBufferPointer { bytes in
        guard let input = readpassphrase(
            "Anthropic key (in memory only): ", bytes.baseAddress, bytes.count, RPP_REQUIRE_TTY
        ) else { throw SecureKeyReaderError.terminalUnavailable }
        let length = strnlen(input, bytes.count)
        guard length < bytes.count - 1 else { throw SecureKeyReaderError.inputTooLong }
        let utf8 = UnsafeBufferPointer(start: input, count: length).map { UInt8(bitPattern: $0) }
        guard let result = String(bytes: utf8, encoding: .utf8) else {
            throw SecureKeyReaderError.invalidEncoding
        }
        return result
    }
}
