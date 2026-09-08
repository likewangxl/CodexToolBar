import XCTest
@testable import MonitorCore

final class SpeechCompletionTests: XCTestCase {
    func testEmptyFinalDoesNotDiscardRecognizedPartial() {
        var result = SpeechCompletion()
        result.accept("请检查当前任务")
        result.accept("")
        result.accept(" \n ")
        XCTAssertEqual(result.text, "请检查当前任务")
        result.accept("请检查当前任务，然后继续。")
        XCTAssertEqual(result.text, "请检查当前任务，然后继续。")
    }
    func testNoInputSilenceAndSlowRecognitionHaveDifferentRecoveryAdvice() {
        XCTAssertTrue(SpeechCompletion.emptyReason(frames: 0, peakDB: -160, timedOut: true).contains("未送入音频"))
        XCTAssertTrue(SpeechCompletion.emptyReason(frames: 48000, peakDB: -90, timedOut: false).contains("输入音量"))
        XCTAssertTrue(SpeechCompletion.emptyReason(frames: 48000, peakDB: -20, timedOut: true).contains("识别超时"))
        XCTAssertTrue(SpeechCompletion.emptyReason(frames: 48000, peakDB: -20, timedOut: false).contains("未识别出文字"))
    }
}
