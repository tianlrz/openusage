import Darwin
import Foundation
import Synchronization
@testable import OpenUsage

@MainActor
final class OrcaQuotaRefreshTests: XCTestCase {
    func testConcurrentCardsShareOneRefreshAndKeepAccountIsolation() async throws {
        let source = QuotaRefreshSource(payload: try Self.payload())
        let reader = OrcaUsageReader(refresh: { try await source.fetch() })
        let readings = try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<40 {
                group.addTask { try await reader.usage(family: "claude", slot: "a").session?.usedPercent ?? -1 }
                group.addTask { try await reader.usage(family: "claude", slot: "b").session?.usedPercent ?? -1 }
            }
            var result: [Double] = []
            for try await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(readings.filter { $0 == 10 }.count, 40)
        XCTAssertEqual(readings.filter { $0 == 80 }.count, 40)
        let calls = await source.count()
        XCTAssertEqual(calls, 1)
    }

    func testRefreshIntervalFailuresAndStaleFallbackKeepOriginalTimestamp() async throws {
        let clock = QuotaRefreshClock()
        let source = QuotaRefreshSource(payload: try Self.payload())
        let reader = OrcaUsageReader(refresh: { try await source.fetch() }, now: { clock.now() })
        let original = try await reader.usage(family: "claude", slot: "a")
        clock.advance(299)
        _ = try await reader.usage(family: "claude", slot: "a")
        let one = await source.count(); XCTAssertEqual(one, 1)
        await source.fail()
        clock.advance(2)
        let stale = try await reader.usage(family: "claude", slot: "a")
        XCTAssertEqual(stale.fetchedAt, original.fetchedAt)
        XCTAssertTrue(stale.warning?.contains("refresh failed") == true)
        _ = try await reader.usage(family: "claude", slot: "a")
        let two = await source.count(); XCTAssertEqual(two, 2)
        let failed = QuotaRefreshSource(payload: try Self.payload())
        await failed.fail()
        let empty = OrcaUsageReader(refresh: { try await failed.fetch() }, now: { clock.now() })
        for _ in 0..<10 {
            do { _ = try await empty.usage(family: "claude", slot: "a"); XCTAssertTrue(false) }
            catch { }
        }
        let attempts = await failed.count(); XCTAssertEqual(attempts, 1)
    }

    func testFramesHandleKeepalivesSplitRepliesAndBoundedMemory() throws {
        var buffer = OrcaQuotaSocket.FrameBuffer()
        XCTAssertNil(try buffer.append(Data("{\"_keepalive\":true}\n{\"id\":".utf8)))
        let frame = try XCTUnwrap(buffer.append(Data("\"request\",\"ok\":true}\n".utf8)))
        XCTAssertEqual(String(decoding: frame, as: UTF8.self), #"{"id":"request","ok":true}"#)
        var oversized = OrcaQuotaSocket.FrameBuffer()
        var rejected = false
        do { _ = try oversized.append(Data(repeating: 65, count: OrcaQuotaSocket.maximumFrameBytes + 1)) }
        catch { rejected = true }
        XCTAssertTrue(rejected)
    }

    func testReplyRequiresMatchingRequestAndRuntimeAndRejectsExcessAccounts() throws {
        let payload = try Self.payloadJSON()
        func frame(id: String = "request", runtime: String = "runtime") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": payload,
                "_meta": ["runtimeId": runtime]])
        }
        let good = try OrcaQuotaSocket.decode(frame(), requestID: "request", runtimeID: "runtime")
        XCTAssertEqual(try good.usage(family: "claude", slot: "b", workspace: nil).session?.usedPercent, 80)
        for data in [try frame(id: "other"), try frame(runtime: "other")] {
            var rejected = false
            do { _ = try OrcaQuotaSocket.decode(data, requestID: "request", runtimeID: "runtime") }
            catch { rejected = true }
            XCTAssertTrue(rejected)
        }
        var crowded = payload
        crowded["claude"] = ["accounts": Array(repeating: ["id": "a"], count: 65)]
        let data = try JSONSerialization.data(withJSONObject: ["id": "request", "ok": true, "result": crowded])
        var rejected = false
        do { _ = try OrcaQuotaSocket.decode(data, requestID: "request", runtimeID: nil) }
        catch { rejected = true }
        XCTAssertTrue(rejected)
    }

    func testNativeSocketRequestRefreshesWithoutSelectingAnAccount() async throws {
        let server = try QuotaSocketFixture()
        defer { server.close() }
        let task = Task.detached { try server.reply() }
        let request = Data(#"{"id":"request","method":"accounts.list","params":{"refreshUsage":true}}"#.utf8) + Data([10])
        let reply = try OrcaQuotaSocket.exchange(endpoint: server.path, request: request, timeout: 2)
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), #"{"id":"request","ok":true}"#)
        let received = try await task.value
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: received) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "accounts.list")
        XCTAssertEqual((object["params"] as? [String: Bool])?["refreshUsage"], true)
    }

    func testSocketTimeoutAndOversizedMetadataFailWithoutWaitingIndefinitely() async throws {
        let server = try QuotaSocketFixture()
        defer { server.close() }
        let task = Task.detached { try server.reply(stall: true) }
        var expired = false
        do { _ = try OrcaQuotaSocket.exchange(endpoint: server.path, request: Data("{}\n".utf8), timeout: 0.05) }
        catch OrcaQuotaSocket.Failure.timedOut { expired = true }
        catch { }
        _ = try await task.value
        XCTAssertTrue(expired)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 32, count: 64 * 1024 + 1).write(to: root.appendingPathComponent("orca-runtime.json"))
        var rejected = false
        do { _ = try OrcaQuotaSocket(root: root).refresh() }
        catch OrcaQuotaSocket.Failure.invalidMetadata { rejected = true }
        catch { }
        XCTAssertTrue(rejected)
        let legacy = try JSONDecoder().decode(OrcaQuotaSocket.Metadata.self,
            from: Data(#"{"authToken":"fixture","transport":{"kind":"unix","endpoint":"/tmp/fixture"}}"#.utf8))
        XCTAssertEqual(legacy.transport?.kind, "unix")
    }

    private static func payload() throws -> OrcaUsageReader.Payload {
        try JSONDecoder().decode(OrcaUsageReader.Payload.self, from: JSONSerialization.data(withJSONObject: payloadJSON()))
    }
    private static func payloadJSON() throws -> [String: Any] {
        let data = Data(#"{"claude":{"accounts":[{"id":"a"},{"id":"b"}],"activeAccountId":"a"},"codex":{"accounts":[]},"rateLimits":{"claudeTarget":{"runtime":"host"},"claude":{"provider":"claude","status":"ok","updatedAt":1800000000000,"session":{"usedPercent":10,"windowMinutes":300}},"inactiveClaudeAccounts":[{"accountId":"b","rateLimits":{"provider":"claude","status":"ok","updatedAt":1800000000000,"session":{"usedPercent":80,"windowMinutes":300}}}]}}"#.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor QuotaRefreshSource {
    let payload: OrcaUsageReader.Payload
    private var calls = 0
    private var failing = false
    init(payload: OrcaUsageReader.Payload) { self.payload = payload }
    func fetch() async throws -> OrcaUsageReader.Payload {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        if failing { throw OrcaQuotaSocket.Failure.unavailable }
        return payload
    }
    func fail() { failing = true }
    func count() -> Int { calls }
}

private final class QuotaRefreshClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { date.withLock { $0 } }
    func advance(_ interval: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(interval) } }
}

private final class QuotaSocketFixture: Sendable {
    let path = "/tmp/quota-\(UUID().uuidString.prefix(12)).sock"
    let descriptor: Int32
    init() throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard descriptor >= 0, result == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor); throw OrcaQuotaSocket.Failure.unavailable
        }
    }
    func close() { Darwin.close(descriptor); unlink(path) }
    func reply(stall: Bool = false) throws -> Data {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 2000) > 0 else { throw OrcaQuotaSocket.Failure.timedOut }
        let peer = accept(descriptor, nil, nil)
        guard peer >= 0 else { throw OrcaQuotaSocket.Failure.unavailable }
        defer { Darwin.close(peer) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(peer, &bytes, bytes.count, 0)
        guard count > 0 else { throw OrcaQuotaSocket.Failure.invalidReply }
        if stall {
            Thread.sleep(forTimeInterval: 0.2)
            return Data(bytes.prefix(count))
        }
        let response = Data("{\"_keepalive\":true}\n{\"id\":\"request\",\"ok\":true}\n".utf8)
        _ = response.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, response.count, 0) }
        return Data(bytes.prefix(count))
    }
}
