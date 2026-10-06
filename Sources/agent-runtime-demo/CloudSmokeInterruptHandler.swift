import Darwin
import Dispatch

/// Smoke-mode process lifetime handler. Signal sources run on a dedicated
/// queue so blocking owner input cannot prevent cancellation cleanup.
final class CloudSmokeInterruptHandler: @unchecked Sendable {
    private let status: CloudSmokeStatus?
    private let savedAttributes: termios?
    private let sources: [any DispatchSourceSignal]

    init(status: CloudSmokeStatus?) {
        self.status = status
        var attributes = termios()
        savedAttributes = tcgetattr(STDIN_FILENO, &attributes) == 0 ? attributes : nil
        let queue = DispatchQueue(label: "agent-runtime-demo.smoke-interrupt")
        let signals = [SIGINT, SIGTERM, SIGHUP]
        sources = signals.map { DispatchSource.makeSignalSource(signal: $0, queue: queue) }
        for (number, source) in zip(signals, sources) {
            // Dispatch delivers signals on its queue. No custom POSIX signal
            // handler performs file I/O, allocation, locking, or JSON encoding.
            Darwin.signal(number, SIG_IGN)
            // Intentional process-lifetime retention: this CLI never uninstalls
            // its handlers, including while its main task is suspended.
            source.setEventHandler { [self] in interrupted(number) }
            source.resume()
        }
    }

    /// readpassphrase can return EINTR before Dispatch delivers the same
    /// signal. Let the queued handler preserve its exact signal exit code.
    /// Other interruptions still fail closed after this bounded grace period.
    func finishInterruptedRead() -> Never {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .seconds(1))
        restoreTerminal()
        status?.record(.failed, failure: .cancelled)
        Darwin._exit(1)
    }

    private func interrupted(_ number: Int32) -> Never {
        restoreTerminal()
        status?.record(.failed, failure: .cancelled)
        Darwin._exit(128 + number)
    }

    private func restoreTerminal() {
        if var attributes = savedAttributes {
            // Restore echo and discard pending input without reading its bytes.
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &attributes)
        }
    }
}
