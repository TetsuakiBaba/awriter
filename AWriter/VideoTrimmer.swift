import AVFoundation
import CoreMedia

/// 録画した mp4 の一部分を切り出して別の mp4 に書き出す。
///
/// AVAssetExportSession は使わない。passthrough プリセットはキーフレーム境界にしか
/// カットできず、品質プリセットは解像度を勝手に丸めてしまうため。ここでは
/// AVAssetReader → AVAssetWriter で読み直し、録画時と同じ H264Settings で書き直す。
/// フレーム単位で正確、かつ解像度もそのまま保たれる。
/// 書き出しの解像度。高さを基準にし、横は元の比のまま合わせる。
enum ExportResolution: String, CaseIterable, Identifiable {
    case original
    case p1080
    case p720

    static let defaultsKey = "exportResolution"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "オリジナル"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    var targetHeight: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 1080
        case .p720: return 720
        }
    }

    /// 実際の書き出し寸法。元より大きくはしない(引き伸ばしても情報は増えないため)。
    func outputSize(for source: CGSize) -> CGSize {
        guard let height = targetHeight, source.height > CGFloat(height), source.height > 0 else {
            return CGSize(width: Self.even(source.width), height: Self.even(source.height))
        }
        let scale = CGFloat(height) / source.height
        return CGSize(width: Self.even(source.width * scale), height: CGFloat(height))
    }

    /// H.264 は偶数寸法を要求する。
    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(Int(value.rounded()) & ~1)
    }
}

enum VideoTrimmer {
    enum TrimError: LocalizedError {
        case noVideoTrack
        case emptyRange
        case writeFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "映像トラックが見つかりませんでした"
            case .emptyRange:
                return "切り出す範囲が空です"
            case .writeFailed(let error):
                return error?.localizedDescription ?? "書き出しに失敗しました"
            }
        }
    }

    /// - Parameter progress: 0...1。任意のスレッドから呼ばれる。
    static func export(
        source: URL,
        range: CMTimeRange,
        to destination: URL,
        resolution: ExportResolution = .original,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard range.duration.isNumeric, range.duration.seconds > 0 else { throw TrimError.emptyRange }

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TrimError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let output = resolution.outputSize(for: naturalSize)

        let job = try TrimJob(asset: asset, track: track, range: range, destination: destination,
                              width: Int(output.width), height: Int(output.height))
        try await job.run(progress: progress)
    }

    /// reader / writer 一式は専用のシリアルキュー上でだけ触られる。
    /// AVFoundation の型は Sendable ではないので、その約束をこのクラスに閉じ込める。
    private final class TrimJob: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let start: CMTime
        private let total: Double
        private let queue = DispatchQueue(label: "jp.ac.tmu.baba.AWriter.trimmer")

        init(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, destination: URL,
             width: Int, height: Int) throws {
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            // ピクセルバッファの寸法を指定すると AVAssetReader が読み出し時に拡縮してくれる。
            output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw TrimError.noVideoTrack }
            reader.add(output)

            try? FileManager.default.removeItem(at: destination)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: H264Settings.video(width: width, height: height))
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw TrimError.noVideoTrack }
            writer.add(input)

            start = range.start
            total = range.duration.seconds
        }

        func run(progress: @escaping @Sendable (Double) -> Void) async throws {
            guard writer.startWriting(), reader.startReading() else {
                throw TrimError.writeFailed(writer.error ?? reader.error)
            }
            writer.startSession(atSourceTime: .zero)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            if reader.status == .failed {
                                writer.cancelWriting()
                                continuation.resume(throwing: TrimError.writeFailed(reader.error))
                            } else {
                                writer.finishWriting {
                                    if self.writer.status == .completed {
                                        progress(1)
                                        continuation.resume()
                                    } else {
                                        continuation.resume(throwing: TrimError.writeFailed(self.writer.error))
                                    }
                                }
                            }
                            return
                        }
                        // 切り出し開始位置が 0 秒になるよう PTS を前倒しする。
                        guard let rebased = VideoTrimmer.rebase(sample, by: start) else { continue }
                        if !input.append(rebased) {
                            reader.cancelReading()
                            writer.cancelWriting()
                            continuation.resume(throwing: TrimError.writeFailed(writer.error))
                            return
                        }
                        let elapsed = CMSampleBufferGetPresentationTimeStamp(rebased).seconds
                        if total > 0 { progress(min(1, max(0, elapsed / total))) }
                    }
                }
            }
        }
    }

    private static func rebase(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr
        else { return nil }

        var timings = [CMSampleTimingInfo](repeating: .invalid, count: max(1, count))
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr
        else { return nil }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - offset
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - offset
            }
        }

        var rebased: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &rebased
        ) == noErr else { return nil }
        return rebased
    }
}
