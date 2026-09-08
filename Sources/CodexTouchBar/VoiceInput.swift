import AppKit
import AVFoundation
import Speech
import OSLog
import MonitorCore

/// Microphone/recognition exist only between an explicit mic tap and Stop.
/// A finished transcript stays in memory until Send/Cancel; audio is never saved.
final class VoiceInputController {
    enum Phase: String { case permission, listening, finishing, review, sending, sent, error, uncertain }
    private(set) var active = false
    var targetTaskID: String? { active ? taskID : nil }
    var diagnosticSummary: String {
        "麦克风权限：\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) · 语音权限：\(SFSpeechRecognizer.authorizationStatus().rawValue)\n语音阶段：\(active ? phase.rawValue : "inactive") · 收音帧数：\(audioFrames) · 文字数：\(transcript.count)"
    }
    private let editor = VoiceEditor()
    private var editing = false
    private var previewOnly = false
    var canSendToTask: ((String) -> Bool)?
    var onDiagnostic: ((String, [String: String]) -> Void)?
    private var phase: Phase = .permission
    private var completion = SpeechCompletion()
    private var audioFrames = 0
    private var peakDB: Float = -160
    private var recognitionMode = ""
    private var probeCompletion: ((String, String) -> Void)?
    private let logger = Logger(subsystem: "local.codex.touchbar", category: "speech")
    private var taskID = "", title = "", transcript = "", status = ""
    private var token = UUID()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var limit: DispatchWorkItem?
    private var finalWait: DispatchWorkItem?
    private var publishWork: DispatchWorkItem?
    private var pager: BarTextPager?
    private var pagedText = ""
    private var page = 0
    private var width: CGFloat = 1004
    private let sender: DesktopInputClient
    private let queue = DispatchQueue(label: "local.codex.touchbar.input", qos: .userInitiated)
    var onUpdate: ((BarDetailSnapshot?) -> Void)?
    init(home: URL) { sender = DesktopInputClient(home: home) }
    func setWidth(_ width: CGFloat) { guard abs(self.width - width) > 1 else { return }; self.width = width; pager = nil; page = 0; if active { publish() } }
    func start(task: TaskState) {
        guard !active else { return }
        active = true; previewOnly = false; taskID = task.id; title = task.title; transcript = ""; page = 0; pager = nil
        if task.connectionIssue != nil { phase = .error; status = "Codex 协议不兼容，请更新本工具后再发送"; publish(); return }
        if UUID(uuidString: task.id) == nil { phase = .error; status = "演示任务无法发送语音"; publish(); return }
        begin()
    }
    private func begin() {
        if previewOnly { phase = .listening; status = "演示状态，不开启麦克风"; publish(); return }
        releaseAudio(); token = UUID(); let current = token
        completion = SpeechCompletion(); audioFrames = 0; peakDB = -160
        transcript = ""; pager = nil; page = 0; phase = .permission; status = "首次使用请允许麦克风和语音识别"; publish()
        // Never request these permissions during launch, rendering, or monitoring.
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self, self.active, self.token == current else { return }
                guard authorization == .authorized else { self.fail("请在系统设置 → 隐私与安全性 → 语音识别中允许本工具"); return }
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self, self.active, self.token == current else { return }
                        guard allowed else { self.fail("请在系统设置 → 隐私与安全性 → 麦克风中允许本工具"); return }
                        self.record(current)
                    }
                }
            }
        }
    }
    private func prepareRecognition(_ current: UUID) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            fail("中文语音识别暂不可用，请检查网络或系统语音设置"); return false
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest(); self.request = request
        request.shouldReportPartialResults = true; request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if #available(macOS 13, *) { request.addsPunctuation = true }
        recognitionMode = recognizer.supportsOnDeviceRecognition ? "本机识别" : "Apple 联网识别"
        status = recognitionMode + " · 等待麦克风音频"
        phase = .listening
        logger.info("Recognition started; onDevice=\(request.requiresOnDeviceRecognition)")
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.active, self.token == current, [.listening, .finishing].contains(self.phase) else { return }
                if let result {
                    self.completion.accept(result.bestTranscription.formattedString)
                    self.transcript = self.completion.text; self.pager = nil; self.page = 0
                    self.logger.info("Result received; final=\(result.isFinal) characters=\(self.transcript.count)")
                    if result.isFinal { self.finishReview(); return }
                    self.schedulePublish()
                }
                if let error {
                    let error = error as NSError
                    self.logger.error("Recognition failed; domain=\(error.domain, privacy: .public) code=\(error.code)")
                    if self.transcript.isEmpty { self.fail(SpeechCompletion.emptyReason(frames: self.audioFrames, peakDB: self.peakDB, timedOut: false) + "（\(error.code)）") }
                    else { self.finishReview(note: "识别已结束 · 请检查文字后发送") }
                }
            }
        }
        return true
    }
    private func record(_ current: UUID) {
        guard prepareRecognition(current), let request else { return }
        let audio = AVAudioEngine(); engine = audio
        let input = audio.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("没有可用麦克风，请检查系统声音输入"); return }
        logger.info("Microphone format; rate=\(format.sampleRate) channels=\(format.channelCount)")
        var totalFrames = 0
        var loudest: Float = -160
        var nextUpdate = ProcessInfo.processInfo.systemUptime
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            totalFrames += Int(buffer.frameLength)
            loudest = max(loudest, Self.level(buffer))
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextUpdate {
                nextUpdate = now + 0.5
                let frames = totalFrames, db = loudest
                DispatchQueue.main.async {
                    guard let self, self.token == current, self.phase == .listening else { return }
                    self.audioFrames = frames; self.peakDB = db
                    let next = self.recognitionMode + (db > -55 ? " · 已收到声音" : " · 声音较轻，请靠近麦克风")
                    if self.status != next { self.status = next; self.publish() }
                }
            }
        }
        tapInstalled = true
        do { audio.prepare(); try audio.start() } catch { fail("麦克风启动失败，请检查声音输入设备"); return }
        phase = .listening; onDiagnostic?("microphoneStarted", [:]); publish()
        let work = DispatchWorkItem { [weak self] in self?.stopRecording() }; limit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 55, execute: work)
    }
    private func stopCapture() {
        limit?.cancel(); limit = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); engine = nil
    }
    private func releaseAudio() {
        stopCapture(); finalWait?.cancel(); finalWait = nil
        recognition?.cancel(); recognition = nil; request = nil; recognizer = nil
        publishWork?.cancel(); publishWork = nil
    }
    private func stopRecording() {
        guard phase == .listening else { return }
        phase = .finishing; status = "麦克风已关闭 · 正在完成识别，请稍候"; stopCapture()
        // endAudio seals the buffer; finish requests processing of ALL accepted audio.
        // cancel is only for cancellation/cleanup after a terminal result or deadline.
        recognition?.finish(); onDiagnostic?("microphoneStopped", ["frames": String(audioFrames), "peakDB": String(peakDB)]); publish()
        logger.info("Audio ended; frames=\(self.audioFrames) peakDB=\(self.peakDB)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .finishing else { return }
            if self.transcript.isEmpty { self.fail(SpeechCompletion.emptyReason(frames: self.audioFrames, peakDB: self.peakDB, timedOut: true)) }
            else { self.finishReview(note: "最终识别超时 · 已保留文字，请检查后发送") }
        }; finalWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SpeechCompletion.finalTimeout, execute: work)
    }
    private func finishReview(note: String = "检查文字 · 点发送给当前任务") {
        phase = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .error : .review
        status = phase == .error ? SpeechCompletion.emptyReason(frames: audioFrames, peakDB: peakDB, timedOut: false) : note
        releaseAudio(); pager = nil; page = 0; onDiagnostic?("speechReview", ["characters": String(transcript.count), "mode": recognitionMode]); publish()
    }
    private func fail(_ message: String) { phase = .error; status = message; releaseAudio(); onDiagnostic?("speechFailed", ["characters": String(transcript.count)]); publish() }
    func cancel() {
        // A submitted request cannot be unsent. Keep its acknowledgement visible.
        guard phase != .sending else { return }
        active = false; token = UUID(); editor.dismiss(); editing = false; releaseAudio(); transcript = ""; pager = nil; onUpdate?(nil)
    }
    func suspend() {
        guard active else { return }
        if phase == .sending { return }
        // Stop capture and invalidate permission/recognition callbacks on lock/sleep.
        token = UUID(); editor.dismiss(); editing = false; releaseAudio()
        if [.sent, .uncertain].contains(phase) { publish(); return }
        phase = .review; status = "录音已停止 · 解锁后检查文字"; publish()
    }
    func shutdown() { active = false; token = UUID(); editor.dismiss(); releaseAudio() }
    func act(_ action: BarDetailAction) {
        switch action {
        case .voiceCancel: cancel()
        case .voiceStop: stopRecording()
        case .voiceRetry: if [.review, .error].contains(phase) { begin() }
        case .voiceSend: send()
        case .voiceEdit: edit()
        case .voiceCopy: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string); status = "已复制 · 请到 Codex 检查发送结果"; publish()
        case .previous: page = max(0, page - 1); publish()
        case .next: if pager?.hasNext(page) == true { page += 1; publish() }
        default: break
        }
    }
    func connectionChanged() { if active { publish() } }
    private func edit() {
        guard active, [.review, .error].contains(phase), !editing else { return }
        editing = true; let session = token, recipient = taskID; publish()
        editor.show(title: title, taskID: recipient, draft: transcript, save: { [weak self] text in
            guard let self, self.active, self.token == session, self.taskID == recipient, self.editing else { return false }
            self.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.editing = false; self.phase = .review; self.status = "文字已修改 · 检查接收任务后发送"
            self.pager = nil; self.page = 0
            self.onDiagnostic?("voiceEdited", ["characters": String(self.transcript.count)])
            self.publish(); return true
        }, cancel: { [weak self] in self?.editing = false; self?.publish() })
    }
    func verifyEditor(to directory: String) -> [String: Bool] {
        let id = taskID; let original = transcript
        act(.voiceEdit)
        var checks = ["editorOpens": editor.window != nil, "editingBlocksSend": editing, "editorRendered": editor.render(to: directory + "/voice-editor.png")]
        editor.verifySave("修正后的技术词：Codex 与 Touch Bar")
        checks["saveChangesDraft"] = transcript == "修正后的技术词：Codex 与 Touch Bar"
        checks["recipientUnchanged"] = taskID == id
        checks["saveOnlyReturnsToReview"] = phase == .review && !editing && editor.window == nil
        act(.voiceEdit); editor.dismiss()
        checks["cancelKeepsSavedDraft"] = transcript == "修正后的技术词：Codex 与 Touch Bar"
        act(.voiceEdit); suspend()
        checks["suspendClosesEditor"] = editor.window == nil && !editing
        phase = .uncertain; suspend()
        checks["uncertainStaysBlockedAfterSuspend"] = phase == .uncertain
        phase = .sent; suspend()
        checks["sentStaysSentAfterSuspend"] = phase == .sent
        phase = .review; transcript = original; publish(); return checks
    }
    private func send() {
        guard phase == .review, !editing, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard canSendToTask?(taskID) != false else { status = "任务协议不兼容，未发送"; publish(); return }
        if previewOnly { status = "演示文字不会发送"; publish(); return }
        phase = .sending; status = "正在发送到此任务…"; publish()
        let id = taskID, text = transcript, current = token
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.sender.send(taskID: id, text: text) }
            DispatchQueue.main.async {
                guard self.active, self.token == current else { return }
                switch result {
                case .success: self.phase = .sent; self.status = "已发送给此任务 · 点返回查看执行"; self.onDiagnostic?("voiceSentAcknowledged", ["taskSuffix": String(id.suffix(8)), "characters": String(text.count)])
                case .failure(let error):
                    self.phase = (error as? DesktopInputError)?.uncertain == true ? .uncertain : .review
                    self.status = error.localizedDescription; self.onDiagnostic?("voiceSendFailed", ["uncertain": String(self.phase == .uncertain)])
                }
                self.publish()
            }
        }
    }
    private func schedulePublish() {
        guard publishWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.publishWork = nil; self?.publish() }; publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func publish() {
        guard active else { return }
        let text = transcript.isEmpty ? status : [.error, .uncertain].contains(phase) || (phase == .review && status != "检查文字 · 点发送给当前任务") ? status + "\n" + transcript : transcript
        if pager == nil || text != pagedText { pager = BarTextPager(text, width: max(60, width - 520)); pagedText = text; page = 0 }
        var value = BarDetailSnapshot()
        value.voice = phase.rawValue; value.title = title; value.subtitle = status
        value.lines = pager?.lines(page) ?? []; value.page = page
        value.previous = page > 0; value.next = pager?.hasNext(page) ?? false
        value.canEdit = [.review, .error].contains(phase) && !editing
        value.canSend = phase == .review && !editing && canSendToTask?(taskID) != false && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onUpdate?(value)
        if [.review, .error].contains(phase), let callback = probeCompletion {
            probeCompletion = nil; callback(transcript, status)
        }
    }
    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0, count = 0
        for i in stride(from: 0, to: Int(buffer.frameLength), by: 16) {
            let value = channels[0][i * buffer.stride]; sum += value * value; count += 1
        }
        return 10 * log10(max(1e-16, sum / Float(max(1, count))))
    }
    /// Recognize a supplied synthetic fixture through the same buffer/finish path.
    /// Never opens a microphone, requests permission, or submits to Codex.
    func probeFile(_ url: URL, completion: @escaping (String, String) -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { completion("", "Speech permission not authorized for this app"); return }
        active = true; title = "合成语音测试"; token = UUID(); probeCompletion = completion
        guard prepareRecognition(token), let request else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 60) else { fail("Fixture exceeds 60 seconds"); return }
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                try file.read(into: buffer)
                audioFrames += Int(buffer.frameLength); peakDB = max(peakDB, Self.level(buffer))
                request.append(buffer)
            }
            stopRecording()
        } catch { fail(error.localizedDescription) }
    }
    // Fixture rendering does not request permission, start capture, or send input.
    func preview(task: TaskState, phase: Phase) {
        active = true; previewOnly = true; taskID = task.id; title = task.title; self.phase = phase
        transcript = "请帮我检查当前任务的执行结果，并继续完成剩下的步骤。"
        status = phase == .listening ? "正在聆听 · 演示文字，未开启麦克风" : "检查文字 · 演示数据，不会发送"
        pager = nil; publish()
    }
}
