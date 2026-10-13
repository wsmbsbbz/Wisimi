import Foundation

final class EdgeOnlineTTSClient {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumFullVersion = "143.0.3650.75"
    private static let chromiumMajorVersion = "143"
    private static let secMSGeCVersion = "2-\(chromiumFullVersion)"
    private static let endpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    private static let timeout: TimeInterval = 45
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/\(chromiumMajorVersion).0.0.0 " +
        "Safari/537.36 Edg/\(chromiumMajorVersion).0.0.0"

    func synthesizeToFile(text: String, speechRate: Double, outputURL: URL) async throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return
        }

        let connectionID = Self.connectionID()
        let socket = URLSession.shared.webSocketTask(with: Self.request(connectionID: connectionID))
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let expiresAt = ContinuousClock.now.advanced(by: .seconds(Self.timeout))
        let deadline = Task {
            try await Task.sleep(for: .seconds(Self.timeout))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await socket.send(.string(Self.speechConfigMessage()))
                try await socket.send(.string(Self.ssmlMessage(requestID: connectionID, text: text, speechRate: speechRate)))
                var audio = Data()
                while true {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    switch message {
                    case .string(let value):
                        if value.contains("Path:turn.end") {
                            guard !audio.isEmpty else { throw EdgeOnlineTTSError.emptyAudio }
                            try audio.write(to: outputURL, options: .atomic)
                            return
                        }
                    case .data(let data):
                        if let payload = Self.audioPayload(from: data), !payload.isEmpty {
                            audio.append(payload)
                        }
                    @unknown default:
                        continue
                    }
                }
            } catch {
                try Task.checkCancellation()
                if ContinuousClock.now >= expiresAt { throw EdgeOnlineTTSError.timeout }
                throw error
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func request(connectionID: String) -> URLRequest {
        let secMSGeC = EdgeSpeechSignature.token()
        let url = URL(string:
            "\(endpoint)?TrustedClientToken=\(trustedClientToken)" +
            "&ConnectionId=\(connectionID)" +
            "&Sec-MS-GEC=\(secMSGeC)" +
            "&Sec-MS-GEC-Version=\(secMSGeCVersion)"
        )!

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("muid=\(connectionID.uppercased());", forHTTPHeaderField: "Cookie")
        return request
    }

    private static func speechConfigMessage() -> String {
        let payload = """
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"\(outputFormat)"}}}}
        """
        return "X-Timestamp:\(edgeDateString())\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            "\(payload)\r\n"
    }

    fileprivate static func ssmlRate(for speechRate: Double) -> Int {
        min(max(Int(((speechRate - 1) * 100).rounded()), 0), 25)
    }

    fileprivate static func ssmlMessage(requestID: String, text: String, speechRate: Double) -> String {
        let rate = ssmlRate(for: speechRate)
        let ssml =
            "<speak version=\"1.0\" " +
            "xmlns=\"http://www.w3.org/2001/10/synthesis\" " +
            "xmlns:mstts=\"https://www.w3.org/2001/mstts\" " +
            "xml:lang=\"zh-CN\">" +
            "<voice name=\"zh-CN-XiaoxiaoNeural\">" +
            "<prosody pitch=\"+0Hz\" rate=\"+\(rate)%\" volume=\"+0%\">\(escapeXML(text))</prosody>" +
            "</voice></speak>"

        return "X-RequestId:\(requestID)\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(edgeDateString())Z\r\n" +
            "Path:ssml\r\n\r\n" +
            ssml
    }

    fileprivate static func audioPayload(from frame: Data) -> Data? {
        if frame.count > 2 {
            let headerLength = Int(frame[frame.startIndex]) * 256 + Int(frame[frame.index(after: frame.startIndex)])
            let payloadStart = headerLength + 2
            if headerLength > 0, payloadStart <= frame.count {
                let headerStart = frame.index(frame.startIndex, offsetBy: 2)
                let headerEnd = frame.index(frame.startIndex, offsetBy: payloadStart)
                let header = String(decoding: frame[headerStart..<headerEnd], as: UTF8.self)
                if header.contains("Path:audio") {
                    return Data(frame[headerEnd...])
                }
            }
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = frame.range(of: separator) else { return nil }
        let header = String(decoding: frame[..<separatorRange.lowerBound], as: UTF8.self)
        guard header.contains("Path:audio") else { return nil }
        return Data(frame[separatorRange.upperBound...])
    }

    static func cacheURL(for text: String, speechRate: Double) -> URL {
        TTSSynthesisRequest(
            model: .edge,
            voiceID: TTSModelID.edge.defaultVoiceID,
            text: text,
            speechRate: speechRate,
            expression: .automatic
        ).cacheURL
    }

    private static func connectionID() -> String {
        (0..<16)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }
            .joined()
    }

    private static func edgeDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

final class EdgeTTSProvider: TTSProviderSynthesizing {
    private let client: EdgeOnlineTTSClient

    init(client: EdgeOnlineTTSClient = EdgeOnlineTTSClient()) {
        self.client = client
    }

    func synthesize(_ request: TTSSynthesisRequest, credential: String?, to outputURL: URL) async throws {
        guard request.model == .edge else { throw TTSSynthesisError.unsupportedConfiguration }
        do {
            try await client.synthesizeToFile(text: request.text, speechRate: request.speechRate, outputURL: outputURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch EdgeOnlineTTSError.timeout {
            throw TTSSynthesisError.timeout
        } catch EdgeOnlineTTSError.emptyAudio {
            throw TTSSynthesisError.emptyAudio
        } catch {
            throw TTSSynthesisError.transport
        }
    }
}

enum EdgeOnlineTTSError: LocalizedError {
    case emptyAudio
    case timeout

    var errorDescription: String? {
        switch self {
        case .emptyAudio: "Edge TTS 未返回音频"
        case .timeout: "Edge TTS 请求超时"
        }
    }
}

#if DEBUG
enum EdgeOnlineTTSSelfCheck {
    static func run() {
        let payload = Data([1, 2, 3])
        let header = Data("Path:audio\r\nX:1".utf8)
        var binaryFrame = Data([UInt8(header.count / 256), UInt8(header.count % 256)])
        binaryFrame.append(header)
        binaryFrame.append(payload)
        assert(EdgeOnlineTTSClient.audioPayload(from: binaryFrame) == payload)

        let crlfFrame = Data("Path:audio\r\n\r\nabc".utf8)
        assert(EdgeOnlineTTSClient.audioPayload(from: crlfFrame) == Data("abc".utf8))

        let nonAudioFrame = Data("Path:turn.end\r\n\r\n".utf8)
        assert(EdgeOnlineTTSClient.audioPayload(from: nonAudioFrame) == nil)
        assert(EdgeOnlineTTSClient.ssmlRate(for: 1.0) == 0)
        assert(EdgeOnlineTTSClient.ssmlRate(for: 1.25) == 25)
        assert(EdgeOnlineTTSClient.cacheURL(for: "hello", speechRate: 1.0) != EdgeOnlineTTSClient.cacheURL(for: "hello", speechRate: 1.25))
        assert(EdgeOnlineTTSClient.ssmlMessage(requestID: "id", text: "hello", speechRate: 1.25).contains("rate=\"+25%\""))
        assert(EdgeSpeechSignature.token(at: 1_700_000_000) == "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2")
        assert(EdgeSpeechSignature.token(at: 1_791_907_200) == "15F3FF629419C5C3-25518D01D8A232E310AF58C808C2B58F6FF62947805FB0F70E013DDA9E88D169")
        assert(EdgeSpeechSignature.token(at: 1_791_907_499) == EdgeSpeechSignature.token(at: 1_791_907_200))
        assert(EdgeSpeechSignature.token(at: 1_791_907_500) == "C9D9CBAF94BE118A-2DDDC327EE532F5937C271B3010E916D04F12E19E00586E8E98938789716A033")
    }
}
#endif
