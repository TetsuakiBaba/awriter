import AVFoundation

// MARK: - エンコード設定(録画とトリム書き出しで共有する)

enum H264Settings {
    /// 画面収録なので文字が潰れないよう高めのビットレートを取る。
    static var bitsPerPixel: Double = 6.0

    static func video(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(width * height) * bitsPerPixel),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }
}
