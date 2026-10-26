import FP
import ProcessSignals

/// A test ran past its deadline.
package struct DeadlineExceeded: Error {
    package init() {}
}

/// Runs `operation` under a wall-clock deadline, so a bug fails the test
/// instead of hanging the suite. Nothing sleeps unless the test hangs.
package func withDeadline<T: Sendable>(
    _ limit: Duration = .seconds(5),
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withTimeout(limit, failingWith: DeadlineExceeded()) {
        Result<T, DeadlineExceeded>.success(await operation())
    }
    .get()
}

/// `signal`'s current handler — `SIG_DFL`, `SIG_IGN` or a function — as bits
/// that compare.
package func disposition(_ signal: Int32) -> UInt {
    bits(currentHandler(signal))
}

/// A handler as bits that compare, e.g. `bits(SIG_IGN)`.
package func bits(_ handler: (@convention(c) (Int32) -> Void)?) -> UInt {
    unsafeBitCast(handler, to: UInt.self)
}
