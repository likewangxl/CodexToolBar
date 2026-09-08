import Foundation

public struct SpeechCompletion {
    public static let finalTimeout: TimeInterval = 25
    public private(set) var text = ""
    public init() {}
    public mutating func accept(_ value: String) {
        // Some final/error callbacks carry an empty hypothesis after a valid partial.
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = value }
    }
    public static func emptyReason(frames: Int, peakDB: Float, timedOut: Bool) -> String {
        if frames == 0 { return "麦克风未送入音频，请检查系统声音输入设备" }
        if peakDB < -55 { return "收到的声音过轻，请检查麦克风输入音量后重录" }
        return timedOut ? "已收到声音，但语音识别超时；请重录" : "已收到声音，但未识别出文字；请重录"
    }
}
