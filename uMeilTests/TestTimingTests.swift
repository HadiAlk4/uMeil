import Testing

struct TestTimingTests {
    @Test func limitsOnlyEverGrow() {
        #expect(TestTiming.scale >= 1)
        #expect(TestTiming.seconds(10) == 10 * TestTiming.scale)
        #expect(TestTiming.duration(.seconds(20)) == .seconds(20) * TestTiming.scale)
    }

    @Test func timeLimitsRoundUpToWholeMinutes() {
        #expect(TestTiming.wholeMinutes(1) == Int(TestTiming.scale.rounded(.up)))
        #expect(TestTiming.wholeMinutes(2) >= 2)
    }
}
