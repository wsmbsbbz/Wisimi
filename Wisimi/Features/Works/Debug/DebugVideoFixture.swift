#if DEBUG
import AVFoundation
import UIKit

enum DebugVideoFixture {
    @MainActor
    static func make() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let silentURL = directory.appendingPathComponent("picture.mp4")
        let audioURL = directory.appendingPathComponent("sound.caf")
        let outputURL = directory.appendingPathComponent("wisimi-check.mp4")
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480, AVVideoHeightKey: 270
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32ARGB),
            size: CVImageSize(width: 480, height: 270)
        )
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 270)).image { context in
            UIColor(red: 0.12, green: 0.24, blue: 0.32, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 270))
            ("Wisimi · MP4" as NSString).draw(at: CGPoint(x: 130, y: 95), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: UIColor.white
            ])
            ("480 × 270 / H.264 + AAC" as NSString).draw(at: CGPoint(x: 133, y: 150), withAttributes: [
                .font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.white
            ])
        }.cgImage!
        for frame in 0..<80 {
            let mutableBuffer = try CVMutablePixelBuffer(attributes)
            mutableBuffer.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 480, height: 270,
                                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 480, height: 270))
                CVPixelBufferUnlockBaseAddress(buffer, [])
            }
            try await receiver.append(CVReadOnlyPixelBuffer(mutableBuffer), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? URLError(.cannotCreateFile) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
        audio.frameLength = audio.frameCapacity
        // A quiet test tone gives the MP4 a real audio track for background playback checks.
        for index in 0..<Int(audio.frameLength) {
            audio.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 220 / 8000)) * 0.01
        }
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: audio)
        let videoAsset = AVURLAsset(url: silentURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let composition = AVMutableComposition()
        let timeRange = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(timeRange, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(timeRange, of: audioTrack, at: .zero)
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await export.export(to: outputURL, as: .mp4)
        return outputURL
    }
}
#endif
