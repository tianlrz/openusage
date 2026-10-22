import Foundation
@testable import OpenUsage
struct FakeEnvironment: EnvironmentReading {
    var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func value(for name: String) -> String? {
        values[name]
    }
}

final class FakeFiles: TextFileAccessing, @unchecked Sendable {
    var files: [String: String]

    init(_ files: [String: String] = [:]) {
        self.files = files
    }

    func exists(_ path: String) -> Bool {
        files[path] != nil
    }

    func readText(_ path: String) throws -> String {
        files[path] ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {
        files[path] = text
    }

    func remove(_ path: String) throws {
        files.removeValue(forKey: path)
    }
}

final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
    var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        value
    }

    func writeGenericPassword(service: String, value: String) throws {
        self.value = value
    }
}
