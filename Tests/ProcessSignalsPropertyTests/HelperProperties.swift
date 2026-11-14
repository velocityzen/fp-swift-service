// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    @testable import ProcessSignals
    import Testing

    /// The array helpers a subscription runs on every call, and signal names.
    @Suite(.hegel)
    struct HelperProperties {
        /// `withoutRepeats` keeps each element where it first appears, once.
        @Test(.hegel(testCases: 1_000))
        func withoutRepeatsKeepsFirstOccurrences() throws {
            try property { tc in
                let signals = try tc.draw(HelperGen.signals, named: "signals")
                let kept = signals.withoutRepeats()
                let firsts = signals.indices.filter { signals.firstIndex(of: signals[$0]) == $0 }
                #expect(kept == firsts.map { signals[$0] })
                if kept.count < signals.count { try tc.event("had repeats") }
            }
        }

        /// `keeping` is `filter`, in order.
        @Test(.hegel(testCases: 1_000))
        func keepingIsFilter() throws {
            try property { tc in
                let signals = try tc.draw(HelperGen.signals, named: "signals")
                let modulus = try tc.draw(.int(in: 1...4), named: "modulus")
                let isIncluded = { (signal: Int32) in Int(signal).magnitude % UInt(modulus) == 0 }
                #expect(signals.keeping(isIncluded) == signals.filter(isIncluded))
            }
        }

        /// Two signals have the same name only if they are the same signal;
        /// a signal without a conventional name is called by its number.
        @Test(.hegel(testCases: 1_000))
        func signalNamesAreDistinct() throws {
            try property { tc in
                let first = try tc.draw(HelperGen.signal, named: "first")
                let second = try tc.draw(HelperGen.signal, named: "second")
                #expect((signalName(first) == signalName(second)) == (first == second))
                let name = signalName(first)
                #expect(name.hasPrefix("SIG") || name == "signal \(first)", "\(first) is \(name)")
            }
        }
    }

    enum HelperGen {
        /// The numbers signals have, mostly; any `Int32` sometimes.
        static let signal: Gen<Int32> = .oneOf(
            Gen.integer(in: 0...34),
            .element(of: [-1, 64, 65, .min, .max]),
            Gen.integer()
        )

        /// Few distinct values, so repeats are common.
        static let signals: Gen<[Int32]> = .oneOf(
            .array(of: Gen.integer(in: 1...4)),
            .array(of: signal)
        )
    }

#endif
