import Darwin
import Foundation

/// Uses Orca's existing local refresh RPC so its owner renews credentials without switching accounts.
struct OrcaQuotaSocket: Sendable {
    static let maximumFrameBytes = 512 * 1024
    var root: URL = OrcaAccountDiscovery.dataRoot(environment: ProcessEnvironmentReader(),
        home: FileManager.default.homeDirectoryForCurrentUser)
    var timeout: TimeInterval = 30

    func refresh() throws -> OrcaUsageReader.Payload {
        let url = root.appendingPathComponent("orca-runtime.json")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw Failure.invalidMetadata }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard !metadata.authToken.isEmpty, metadata.authToken.utf8.count <= 4096,
              let transport = (metadata.transports ?? metadata.transport.map { [$0] } ?? [])
                .first(where: { $0.kind == "unix" }) else { throw Failure.invalidMetadata }
        let id = UUID().uuidString
        let request = Request(id: id, authToken: metadata.authToken)
        let frame = try Self.exchange(endpoint: transport.endpoint,
            request: JSONEncoder().encode(request) + Data([10]), timeout: timeout)
        return try Self.decode(frame, requestID: id, runtimeID: metadata.runtimeId)
    }

    struct Metadata: Decodable {
        var authToken: String
        var runtimeId: String?
        var transports: [Transport]?
        var transport: Transport?
    }
    struct Transport: Decodable { var kind: String; var endpoint: String }
    private struct Request: Encodable {
        var id: String
        var authToken: String
        var method = "accounts.list"
        var params = Parameters()
        struct Parameters: Encodable { var refreshUsage = true }
    }
    private struct Reply: Decodable {
        var id: String
        var ok: Bool
        var result: OrcaUsageReader.Payload?
        var _meta: ReplyMetadata?
    }
    private struct ReplyMetadata: Decodable { var runtimeId: String? }

    static func decode(_ frame: Data, requestID: String, runtimeID: String?) throws -> OrcaUsageReader.Payload {
        guard frame.count <= maximumFrameBytes else { throw Failure.oversizedResponse }
        let reply = try JSONDecoder().decode(Reply.self, from: frame)
        guard reply.id == requestID,
              runtimeID == nil || reply._meta?.runtimeId == nil || reply._meta?.runtimeId == runtimeID,
              reply.ok, let result = reply.result,
              result.claude.accounts.count <= 64, result.codex.accounts.count <= 64,
              (result.rateLimits.inactiveClaudeAccounts?.count ?? 0) <= 64,
              (result.rateLimits.inactiveCodexAccounts?.count ?? 0) <= 64 else { throw Failure.invalidReply }
        return result
    }

    static func exchange(endpoint: String, request: Data, timeout: TimeInterval) throws -> Data {
        guard !request.isEmpty, request.count <= 16 * 1024, timeout > 0, timeout <= 60 else {
            throw Failure.invalidMetadata
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unavailable }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(endpoint.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.invalidMetadata }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        let deadline = Date().addingTimeInterval(timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw Failure.unavailable }
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw Failure.unavailable
            }
        }
        var sent = 0
        while sent < request.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let written = request.withUnsafeBytes {
                guard let base = $0.baseAddress else { return 0 }
                return Darwin.send(descriptor, base.advanced(by: sent), request.count - sent, 0)
            }
            if written < 0, errno == EAGAIN || errno == EINTR { continue }
            guard written > 0 else { throw Failure.unavailable }
            sent += written
        }
        var frames = FrameBuffer()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }
            if let result = try frames.append(Data(chunk.prefix(count))) { return result }
        }
    }

    struct FrameBuffer {
        private var pending = Data()
        private var totalBytes = 0
        mutating func append(_ chunk: Data) throws -> Data? {
            totalBytes += chunk.count
            guard totalBytes <= OrcaQuotaSocket.maximumFrameBytes else { throw Failure.oversizedResponse }
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<end])
                pending.removeSubrange(...end)
                if frame.isEmpty { continue }
                let heartbeat = try JSONDecoder().decode(Heartbeat.self, from: frame)
                if heartbeat._keepalive == true { continue }
                return frame
            }
            return nil
        }
        private struct Heartbeat: Decodable { var _keepalive: Bool? }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.timedOut }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw Failure.timedOut }
            guard item.revents & events != 0 else { throw Failure.unavailable }
            return
        }
    }

    enum Failure: Error, LocalizedError {
        case unavailable, invalidMetadata, invalidReply, oversizedResponse, timedOut
        var errorDescription: String? {
            "Orca's live quota refresh is unavailable. Saved readings keep their original timestamps."
        }
    }
}
