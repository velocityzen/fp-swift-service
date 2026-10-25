#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import FPService

/// The README's walkthrough as a runnable CLI: one subcommand per step.
/// Code between `readme:begin` and `readme:end` is shown verbatim in
/// README.md and the DocC articles.
@main
struct Example: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Example",
        abstract: "The README's walkthrough, one step per subcommand.",
        subcommands: [QuickStart.self, Events.self, Job.self, Requests.self, Drain.self],
        defaultSubcommand: QuickStart.self
    )
}

struct QuickStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quickstart",
        abstract: "Start the services and stop them on Ctrl-C."
    )

    func run() async throws {
        // readme:begin quickstart
        let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
        let result = await withService()
        // readme:end quickstart
        try report(result)
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Also print every lifecycle event."
    )

    func run() async throws {
        // readme:begin events
        let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM]) { events in
            for await event in events {
                switch event {
                    case .success(let event): print("event: \(event)")
                    case .failure(let error): print("error: \(error)")
                }
            }
        }
        let result = await withService()
        // readme:end events
        try report(result)
    }
}

struct Job: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "job",
        abstract: "Run a body that does some work and returns."
    )

    func run() async throws {
        // readme:begin runjob
        let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
        let result = await withService(importBatches)
        // readme:end runjob
        try report(result)
    }
}

struct Requests: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "requests",
        abstract: "Run a body that handles requests until Ctrl-C."
    )

    func run() async throws {
        // readme:begin runrequests
        let withService = Service(
            withDependencies(),
            shutdownSignals: [SIGINT, SIGTERM],
            shutdownTimeout: .seconds(10)
        )
        let result = await withService(handleRequests)
        // readme:end runrequests
        try report(result)
    }
}

struct Drain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drain",
        abstract: "Run a server that finishes the request in flight on Ctrl-C."
    )

    func run() async throws {
        // readme:begin rundrain
        let withService = Service(
            withDependencies(),
            shutdownSignals: [SIGINT, SIGTERM],
            shutdownTimeout: .seconds(10)
        )
        let result = await withService(drainRequests)
        // readme:end rundrain
        try report(result)
    }
}

/// Prints how the run ended; a failure exits with status 1.
func report(_ result: Result<ServiceOutcome, ServiceError<ExampleError>>) throws {
    switch result {
        case .success(let outcome): print("outcome: \(outcome)")
        case .failure(let error):
            print("failed: \(error)")
            throw ExitCode.failure
    }
}
