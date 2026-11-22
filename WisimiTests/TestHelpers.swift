import AVFoundation
import Foundation
import Testing
@testable import Wisimi

private final class TestBundleToken {}

enum TestFixtures {
    static var silenceMP3URL: URL {
        let bundle = Bundle(for: TestBundleToken.self)
        if let url = bundle.url(forResource: "silence", withExtension: "mp3") {
            return url
        }
        if let url = bundle.url(forResource: "silence", withExtension: "mp3", subdirectory: "Fixtures") {
            return url
        }
        fatalError("Missing silence.mp3 in WisimiTests bundle")
    }
}

enum TestWaitError: Error {
    case timedOut
}

@MainActor
func waitUntil(_ condition: () -> Bool, maxAttempts: Int = 500, intervalMilliseconds: Int = 10) async throws {
    for _ in 0..<maxAttempts {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(intervalMilliseconds))
    }
    throw TestWaitError.timedOut
}

@MainActor
final class SpeechStub: TTSProviderSynthesizing {
    var requests: [TTSSynthesisRequest] = []
    var failures: [Error] = []
    var invalidAudio = false
    var shouldSuspend = false
    var pending: CheckedContinuation<Void, Never>?

    func synthesize(_ request: TTSSynthesisRequest, credential: String?, to outputURL: URL) async throws {
        requests.append(request)
        if shouldSuspend { await withCheckedContinuation { pending = $0 } }
        if !failures.isEmpty { throw failures.removeFirst() }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        integer(UInt32(4836)); data.append(Data("WAVEfmt ".utf8)); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(24000)); integer(UInt32(48000))
        integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(UInt32(4800))
        data.append(Data(repeating: 0, count: 4800))
        if request.cacheFileExtension == "mp3" {
            data = try Data(contentsOf: TestFixtures.silenceMP3URL)
        }
        try (invalidAudio ? Data("invalid".utf8) : data).write(to: outputURL, options: .atomic)
        #expect(invalidAudio || TTSCache.containsValidAudio(at: outputURL))
    }
}

final class HTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, String))!
    nonisolated(unsafe) static var respondWithHeaders: ((URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var stream: ((HTTPStub) -> Bool)?
    nonisolated(unsafe) static var hold: ((HTTPStub) -> Bool)?
    nonisolated(unsafe) static var payload: Data?

    private let cancelLock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.hold?(self) == true { return }
        if Self.stream?(self) == true { return }
        do {
            if let respondWithHeaders = Self.respondWithHeaders {
                let (status, headers, data) = try respondWithHeaders(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let (status, body) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload ?? Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    func finish(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func reset() {
        respond = nil
        respondWithHeaders = nil
        stream = nil
        hold = nil
        payload = nil
    }
}

final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [HTTPStub] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    func hold(_ request: HTTPStub) -> Bool {
        lock.lock(); defer { lock.unlock() }
        held.append(request)
        return true
    }

    func finish(_ body: (URLRequest) -> String) {
        lock.lock(); let requests = held; held = []; lock.unlock()
        for request in requests { request.finish(body(request.request)) }
    }
}

func makeStubClient() -> ASMRClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPStub.self]
    return ASMRClient(session: URLSession(configuration: configuration))
}

final class InMemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]

    private func key(for query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)::\(account)"
    }

    var operations: KeychainOperations {
        KeychainOperations(
            read: { [weak self] query in
                guard let self else { return (errSecItemNotFound, nil) }
                lock.lock(); defer { lock.unlock() }
                guard let data = entries[key(for: query)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            },
            update: { [weak self] query, attributes in
                guard let self else { return errSecItemNotFound }
                lock.lock(); defer { lock.unlock() }
                let k = key(for: query)
                guard entries[k] != nil else { return errSecItemNotFound }
                if let data = attributes[kSecValueData as String] as? Data {
                    entries[k] = data
                }
                return errSecSuccess
            },
            add: { [weak self] attributes in
                guard let self else { return errSecAllocate }
                lock.lock(); defer { lock.unlock() }
                let k = key(for: attributes)
                guard entries[k] == nil else { return errSecDuplicateItem }
                entries[k] = attributes[kSecValueData as String] as? Data ?? Data()
                return errSecSuccess
            },
            delete: { [weak self] query in
                guard let self else { return errSecItemNotFound }
                lock.lock(); defer { lock.unlock() }
                let k = key(for: query)
                return entries.removeValue(forKey: k) != nil ? errSecSuccess : errSecItemNotFound
            }
        )
    }
}
