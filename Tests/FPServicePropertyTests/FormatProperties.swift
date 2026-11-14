// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    @testable import FPService
    import HegelTesting
    import Testing

    /// `format(_:)`, the durations in log lines: `10 s`, `1.5 s`, `250 ms`,
    /// `0.042 ms`.
    @Suite(.hegel)
    struct FormatProperties {
        /// Read back, the text is the duration to the nearest microsecond
        /// below a second and the nearest millisecond from it, with at most
        /// three decimals and no trailing zeros; a negative duration is its
        /// magnitude with a minus sign.
        @Test(.hegel(testCases: 2_000))
        func formatReadsBackToTheDuration() throws {
            try property(examples: Self.boundaries, reaching: ["in seconds", "in milliseconds"]) {
                tc in
                let duration = try tc.draw(FormatGen.duration, named: "duration")
                let text = format(duration)
                guard duration >= .zero else {
                    #expect(text == "-" + format(.zero - duration), "a negative duration")
                    return
                }
                let read = try #require(Formatted(text), "\(text) doesn't read as a duration")
                #expect(read.decimals.count <= 3, "\(text) has more than three decimals")
                #expect(read.decimals.last != "0", "\(text) ends in a zero")

                // Half up: the nearest unit, the higher one at a tie.
                let error = read.attoseconds - attoseconds(duration)
                #expect(
                    -read.unit / 2 < error && error <= read.unit / 2,
                    "\(text) is \(error) attoseconds off \(duration)"
                )
                // Milliseconds for what rounds to below a second.
                let belowASecond = attoseconds(duration) < Self.second - Self.microsecond / 2
                #expect((read.unit == Self.microsecond) == belowASecond, "\(text): the wrong unit")
                try tc.event(read.unit == Self.microsecond ? "in milliseconds" : "in seconds")
            }
        }

        static let second: Int128 = 1_000_000_000_000_000_000
        static let microsecond: Int128 = 1_000_000_000_000

        /// Where the unit and the rounding change.
        static let boundaries: [Example] = [
            .zero, .nanoseconds(499), .nanoseconds(500), .microseconds(999_999),
            Duration(attoseconds: second - microsecond / 2 - 1),
            Duration(attoseconds: second - microsecond / 2), .seconds(1),
            Duration(attoseconds: 2 * second - second / 2000), .milliseconds(1500), .seconds(-1),
        ].map { ["duration": $0] }
    }

    enum FormatGen {
        /// A tie, one either side of it, or anything, for each unit; then
        /// any attoseconds at all.
        static let fraction: Gen<Int64> = .oneOf(
            .element(of: [0, 499_999_999_999, 500_000_000_000, 500_000_000_001]),
            .element(of: [999_999_499_999_999_999, 999_999_500_000_000_000]),
            .element(of: [499_999_999_999_999, 500_000_000_000_000, 999_500_000_000_000_000]),
            Gen.integer(in: 0...999_999_999_999).map { $0 * 1_000_000 },
            Gen.integer(in: 0...999_999_999_999_999_999)
        )

        /// Seconds a stop takes, a day, a century, or any: `format` traps
        /// only where rounding up passes `Int64.max` seconds.
        static let seconds: Gen<Int64> = .oneOf(
            .element(of: [0, 1, 9]),
            Gen.integer(in: 0...86_400),
            Gen.integer(in: 0...3_155_760_000),
            Gen.integer(in: 0...(Int64.max - 1))
        )

        static let duration: Gen<Duration> = Hegel.zip(seconds, fraction, .bool(probability: 0.1))
            .map { seconds, attoseconds, negative in
                let duration = Duration(
                    secondsComponent: seconds,
                    attosecondsComponent: attoseconds
                )
                return negative ? .zero - duration : duration
            }
    }

    private func attoseconds(_ duration: Duration) -> Int128 {
        let (seconds, attoseconds) = duration.components
        return Int128(seconds) * FormatProperties.second + Int128(attoseconds)
    }

    /// A formatted duration, read back: `1.25 s` or `0.042 ms`.
    private struct Formatted {
        var attoseconds: Int128
        /// What the last decimal place counts: a millisecond or a microsecond.
        var unit: Int128
        var decimals: Substring

        init?(_ text: String) {
            let parts = text.split(separator: " ")
            guard parts.count == 2 else { return nil }
            let scale: Int128
            switch parts[1] {
                case "s": scale = FormatProperties.second
                case "ms": scale = FormatProperties.second / 1000
                default: return nil
            }
            let number = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(number.count), let whole = Int128(number[0]), whole >= 0 else {
                return nil
            }
            decimals = number.count == 2 ? number[1] : ""
            guard decimals.allSatisfy(\.isASCII), decimals.allSatisfy(\.isNumber) else {
                return nil
            }
            guard number.count == 1 || !decimals.isEmpty else { return nil }
            var fraction: Int128 = 0
            var place = scale
            for digit in decimals {
                place /= 10
                fraction += Int128(digit.wholeNumberValue!) * place
            }
            attoseconds = whole * scale + fraction
            unit = scale / 1000
        }
    }

#endif
