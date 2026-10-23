import XCTest

@MainActor
final class TranscriptionDeadlineTests: XCTestCase {

    func testRecordingUsesAnEngineThatWasReadyAtStart() {
        XCTAssertTrue(RecordingReadiness.isReady(
            wasReadyAtStart: true,
            sameEngineIsReadyAtStop: false
        ))
    }

    func testRecordingUsesTheSameEngineWhenWarmupFinishesWhileSpeaking() {
        XCTAssertTrue(RecordingReadiness.isReady(
            wasReadyAtStart: false,
            sameEngineIsReadyAtStop: true
        ))
    }

    func testRecordingRejectsAnEngineThatNeverBecameReady() {
        XCTAssertFalse(RecordingReadiness.isReady(
            wasReadyAtStart: false,
            sameEngineIsReadyAtStop: false
        ))
    }

    func testSuccessfulOperationReportsLifecycleExactlyOnce() async throws {
        let lifecycle = LifecycleProbe()
        let lifecycleFinished = expectation(description: "successful operation lifecycle completion")
        Task {
            await lifecycle.waitUntilFinished()
            lifecycleFinished.fulfill()
        }

        let value = try await TranscriptionDeadline.run(
            for: .seconds(86_400),
            onOperationFinished: { Task { await lifecycle.markFinished() } }
        ) {
            "finished transcript"
        }

        await fulfillment(of: [lifecycleFinished], timeout: 1)
        await Task.yield()
        XCTAssertEqual(value, "finished transcript")
        let finishCount = await lifecycle.finishCount()
        XCTAssertEqual(finishCount, 1)
    }

    func testDeadlineCancelsASuspendedOperationWhenTheInjectedSleeperFires() async {
        // Arrange
        let probe = DeadlineProbe()
        let lifecycle = LifecycleProbe()
        let cancellationObserved = expectation(description: "operation cancellation")
        let lifecycleFinished = expectation(description: "timed-out operation lifecycle completion")
        let runner = Task.detached { [probe] in
            do {
                _ = try await TranscriptionDeadline.run(
                    for: .seconds(30),
                    sleep: { _ in await probe.waitUntilStarted() },
                    onOperationFinished: { Task { await lifecycle.markFinished() } }
                ) {
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(86_400))
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw CancellationError()
                    }
                    return ()
                }
            } catch let error as TranscriptionError {
                if case .timedOut = error { await probe.markTimedOut() }
            } catch {
                await probe.markUnexpectedError()
            }
        }
        Task {
            await probe.waitUntilCancelled()
            cancellationObserved.fulfill()
        }
        Task {
            await lifecycle.waitUntilFinished()
            lifecycleFinished.fulfill()
        }

        // Act
        await fulfillment(of: [cancellationObserved, lifecycleFinished], timeout: 1)
        await runner.value

        // Assert
        let result = await probe.result()
        XCTAssertTrue(result.didTimeOut)
        XCTAssertFalse(result.didReceiveUnexpectedError)
        let finishCount = await lifecycle.finishCount()
        XCTAssertEqual(finishCount, 1)
    }

    func testDeadlineReturnsTimedOutBeforeANonCooperativeOperationIsReleased() async {
        // Regression: a throwing task group waits for every child at scope exit, so a native
        // inference call that ignores cancellation used to keep the retry watchdog hung.
        // Arrange
        let gate = NonCooperativeGate()
        let probe = TimeoutProbe()
        let lifecycle = LifecycleProbe()
        let timeoutObserved = expectation(description: "deadline returns before inference releases")
        let operationFinished = expectation(description: "operation completion is reported after release")
        let runner = Task.detached { [gate, probe] in
            do {
                _ = try await TranscriptionDeadline.run(
                    for: .seconds(30),
                    sleep: { _ in await gate.waitUntilOperationStarts() },
                    onOperationFinished: { Task { await lifecycle.markFinished() } }
                ) {
                    await gate.markOperationStarted()
                    await gate.waitUntilReleasedIgnoringCancellation()
                    return "late transcript"
                }
                await probe.markUnexpectedCompletion()
            } catch let error as TranscriptionError {
                if case .timedOut = error { await probe.markTimedOut() }
            } catch {
                await probe.markUnexpectedError()
            }
        }
        Task {
            await probe.waitUntilTimedOut()
            timeoutObserved.fulfill()
        }
        Task {
            await lifecycle.waitUntilFinished()
            operationFinished.fulfill()
        }

        // Act
        await fulfillment(of: [timeoutObserved], timeout: 1)

        // Assert
        let result = await probe.result()
        XCTAssertFalse(result.didUnexpectedlyComplete)
        XCTAssertFalse(result.didReceiveUnexpectedError)
        let finishCountBeforeRelease = await lifecycle.finishCount()
        XCTAssertEqual(finishCountBeforeRelease, 0)

        // Cleanup: unblock the intentionally non-cooperative orphan before this test returns.
        await gate.release()
        await fulfillment(of: [operationFinished], timeout: 1)
        await runner.value
        await Task.yield()
        let finishCountAfterRelease = await lifecycle.finishCount()
        XCTAssertEqual(finishCountAfterRelease, 1)
    }

    func testImmediateCallerCancellationStillReportsOperationLifecycleCompletion() async {
        // Regression: cancellation could win before the internal task installed its
        // continuation, so no native operation existed and its completion callback never fired.
        let probe = TimeoutProbe()
        let lifecycle = LifecycleProbe()
        let lifecycleFinished = expectation(description: "lifecycle completion after immediate cancel")
        let runner = Task.detached { [probe] in
            do {
                _ = try await TranscriptionDeadline.run(
                    for: .seconds(30),
                    onOperationFinished: { Task { await lifecycle.markFinished() } }
                ) {
                    try await Task.sleep(for: .seconds(86_400))
                    return ()
                }
            } catch {
                // Cancellation is the expected caller outcome.
            }
        }
        runner.cancel()
        Task {
            await lifecycle.waitUntilFinished()
            lifecycleFinished.fulfill()
        }

        await fulfillment(of: [lifecycleFinished], timeout: 1)
        await runner.value
        await Task.yield()
        let finishCount = await lifecycle.finishCount()
        XCTAssertEqual(finishCount, 1)
    }
}

/// `onOperationFinished` is synchronous and `@Sendable`; this actor lets the tests
/// observe its asynchronous bridge without giving the worker access to XCTest objects.
private actor LifecycleProbe {
    private var completions = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markFinished() {
        completions += 1
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilFinished() async {
        guard completions > 0 else {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
    }

    func finishCount() -> Int { completions }
}

private actor DeadlineProbe {
    private var started = false
    private var cancelled = false
    private var timedOut = false
    private var unexpectedError = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func result() -> (didTimeOut: Bool, didReceiveUnexpectedError: Bool) {
        (timedOut, unexpectedError)
    }

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func markCancelled() {
        cancelled = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }

    func markTimedOut() { timedOut = true }
    func markUnexpectedError() { unexpectedError = true }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

private actor NonCooperativeGate {
    private var operationStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markOperationStarted() {
        operationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilOperationStarts() async {
        guard !operationStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilReleasedIgnoringCancellation() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor TimeoutProbe {
    private var timedOut = false
    private var unexpectedlyCompleted = false
    private var unexpectedError = false
    private var operationFinished = false
    private var timeoutWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationFinishedWaiters: [CheckedContinuation<Void, Never>] = []

    func markTimedOut() {
        timedOut = true
        timeoutWaiters.forEach { $0.resume() }
        timeoutWaiters.removeAll()
    }

    func markUnexpectedCompletion() { unexpectedlyCompleted = true }
    func markUnexpectedError() { unexpectedError = true }
    func markOperationFinished() {
        operationFinished = true
        operationFinishedWaiters.forEach { $0.resume() }
        operationFinishedWaiters.removeAll()
    }

    func waitUntilTimedOut() async {
        guard !timedOut else { return }
        await withCheckedContinuation { timeoutWaiters.append($0) }
    }

    func waitUntilOperationFinished() async {
        guard !operationFinished else { return }
        await withCheckedContinuation { operationFinishedWaiters.append($0) }
    }

    func result() -> (
        didUnexpectedlyComplete: Bool,
        didReceiveUnexpectedError: Bool,
        didOperationFinish: Bool
    ) {
        (unexpectedlyCompleted, unexpectedError, operationFinished)
    }
}
