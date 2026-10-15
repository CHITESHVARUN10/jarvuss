import XCTest
@testable import JarvisMacOS

private final class ModelProtocol: URLProtocol {
    static let lock = NSLock()
    static var didStart: (() -> Void)?
    static var didStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.didStart }?()
        guard request.url?.path != "/blocked" else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"response":"ready"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.lock.withLock { Self.didStop }?() }
}

final class OllamaCancellationTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelProtocol.self]
        session = URLSession(configuration: configuration)
        ModelProtocol.lock.withLock { ModelProtocol.didStart = nil; ModelProtocol.didStop = nil }
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ModelProtocol.lock.withLock { ModelProtocol.didStart = nil; ModelProtocol.didStop = nil }
    }

    func testDeadlineStopsHTTPAndReleasesInferenceSlot() async {
        let started = expectation(description: "HTTP started")
        let stopped = expectation(description: "HTTP cancelled")
        ModelProtocol.lock.withLock {
            ModelProtocol.didStart = { started.fulfill() }
            ModelProtocol.didStop = { stopped.fulfill() }
        }
        let gate = InferenceGate()
        let client = OllamaClient(endpoint: URL(string: "http://model.test/blocked")!, session: session, gate: gate)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await client.generate(prompt: "slow", timeout: 0.15)
        XCTAssertTrue(OllamaClient.isFailure(result))
        XCTAssertLessThan(clock.now - start, .seconds(2))
        await fulfillment(of: [started, stopped], timeout: 1)
        ModelProtocol.lock.withLock { ModelProtocol.didStart = nil; ModelProtocol.didStop = nil }
        let next = OllamaClient(endpoint: URL(string: "http://model.test/ready")!, session: session, gate: gate)
        let nextResult = await next.generate(prompt: "next", timeout: 1)
        XCTAssertEqual(nextResult, "ready")
    }

    func testQueuedDeadlineNeverStartsHTTPOrLeaksPermit() async throws {
        let gate = InferenceGate()
        try await gate.acquire()
        let unexpected = expectation(description: "queued expired request must not start")
        unexpected.isInverted = true
        ModelProtocol.lock.withLock { ModelProtocol.didStart = { unexpected.fulfill() } }
        let client = OllamaClient(endpoint: URL(string: "http://model.test/ready")!, session: session, gate: gate)
        let result = await client.generate(prompt: "waiting", timeout: 0.05)
        XCTAssertEqual(result, OllamaClient.timeoutMessage)
        await fulfillment(of: [unexpected], timeout: 0.05)
        ModelProtocol.lock.withLock { ModelProtocol.didStart = nil }
        await gate.release()
        let next = await client.generate(prompt: "next", timeout: 1)
        XCTAssertEqual(next, "ready")
    }

    func testCallerCancellationStopsActiveRequest() async {
        let started = expectation(description: "HTTP started")
        let stopped = expectation(description: "HTTP cancelled")
        ModelProtocol.lock.withLock {
            ModelProtocol.didStart = { started.fulfill() }
            ModelProtocol.didStop = { stopped.fulfill() }
        }
        let client = OllamaClient(endpoint: URL(string: "http://model.test/blocked")!, session: session, gate: InferenceGate())
        let task = Task { await client.generate(prompt: "cancel me", timeout: 10) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        XCTAssertTrue(OllamaClient.isFailure(result))
        await fulfillment(of: [stopped], timeout: 1)
    }
}
