import FPBracket
import FPService
import Synchronization

// The README's example services. Code between `readme:begin` and
// `readme:end` is shown verbatim in README.md and the DocC articles.
//
// These are top-level functions, so they are not on the main actor:
// `Service` takes the bracket as `sending`, and closures written on the main
// actor are isolated to it and cannot be sent.

/// The services' own error type; it comes back untouched in `ServiceError`.
enum ExampleError: Error {
    case unavailable
}

struct Database: Sendable {}

// readme:begin server
/// Stands in for a server library with its own graceful stop.
final class Server: Sendable {
    let database: Database
    private let accepting = Mutex(true)

    init(database: Database) {
        self.database = database
    }

    /// Handles requests until `beginGracefulShutdown()`, then finishes the
    /// one in flight and returns.
    func run() async -> Result<Void, ExampleError> {
        var request = 0
        while accepting.withLock({ $0 }) {
            request += 1
            print("handling request \(request)")
            try? await Task.sleep(for: .seconds(1))
            print("finished request \(request)")
        }
        return .success(())
    }

    /// Stops taking new requests; `run()` returns once the current one is done.
    func beginGracefulShutdown() {
        accepting.withLock { $0 = false }
    }
}
// readme:end server

// readme:begin brackets
func withDatabase() -> BracketAsync<Database, ExampleError> {
    BracketAsync(
        acquire: {
            print("database: open")
            return .success(Database())
        },
        dispose: { _ in
            print("database: closed")
            return .success(())
        }
    )
}

func withServer(_ database: Database) -> BracketAsync<Server, ExampleError> {
    BracketAsync(
        acquire: {
            print("server: listening")
            return .success(Server(database: database))
        },
        dispose: { _ in
            print("server: closed")
            return .success(())
        }
    )
}
// readme:end brackets

// readme:begin dependencies
func withDependencies() -> BracketAsync<(Database, Server), ExampleError> {
    BracketAsyncDo<ExampleError>()
        .bind { withDatabase() }
        .bind { database in withServer(database) }
}
// readme:end dependencies

// readme:begin job
/// Does a fixed amount of work, then returns — which stops the service.
func importBatches(
    _ resources: (Database, Server),
    _: Shutdown
) async -> Result<Void, ExampleError> {
    for batch in 1...3 {
        try? await Task.sleep(for: .seconds(1))
        print("imported batch \(batch)")
    }
    return .success(())
}
// readme:end job

// readme:begin requests
/// Handles requests until shutdown is requested, then stops and returns.
func handleRequests(_ resources: (Database, Server), _ shutdown: Shutdown) async -> Result<
    Void, ExampleError
> {
    await withCancellation(on: shutdown, work)
}

/// Handles a request once a second until cancelled.
func work() async -> Result<Void, ExampleError> {
    var request = 0
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        request += 1
        print("handled request \(request)")
    }
    return .success(())
}
// readme:end requests

// readme:begin drain
/// Lets the server finish the request in flight instead of cancelling it.
func drainRequests(_ resources: (Database, Server), _ shutdown: Shutdown) async -> Result<
    Void, ExampleError
> {
    let (_, server) = resources
    return await withShutdownHandler(on: shutdown, server.beginGracefulShutdown) {
        await server.run()
    }
}
// readme:end drain
