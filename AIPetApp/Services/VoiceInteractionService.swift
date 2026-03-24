import Foundation
import AVFoundation
import Speech
import Accelerate

/// 全双工语音交互服务：
/// - 使用 AVAudioEngine 做实时录音
/// - 基于简单能量阈值实现 VAD（语音活动检测）
/// - 通过系统 Speech 框架做本地/云端语音识别
/// - 暴露打断信号：当检测到新的说话段落时，可用于打断当前 TTS 播报
final class VoiceInteractionService: NSObject, ObservableObject {

    // 对外可观察状态
    @Published var isRunning: Bool = false
    @Published var transcribedText: String? = nil
    @Published var environmentSummary: String? = nil
    @Published var isSpeaking: Bool = false

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// 最近一小段时间内的输入能量，用于估算环境噪声水平
    private var recentPowerLevels: [Float] = []
    private let powerWindowSize = 25

    /// 简单节流：在前一次完整说话段落结束后，避免立即再次触发
    private var lastUtteranceAt: Date = .distantPast

    override init() {
        super.init()
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        requestPermissionsIfNeeded { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return
            }

            DispatchQueue.main.async {
                self.startInternal()
            }
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("停用音频会话失败: \(error)")
        }

        DispatchQueue.main.async {
            self.isRunning = false
            self.transcribedText = nil
        }
    }

    // MARK: - Internal setup

    private func startInternal() {
        configureAudioSessionIfNeeded()

        let inputNode = audioEngine.inputNode

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                // 仅在当前一轮说话结束时输出完整转写结果，避免对部分结果频繁触发对话
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.transcribedText = text
                    }
                    self.lastUtteranceAt = Date()
                }
            }

            if error != nil {
                self.stop()
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.recognitionRequest?.append(buffer)
            self.handleVADAndEnvironment(from: buffer)
        }

        do {
            try audioEngine.start()
            isRunning = true
        } catch {
            print("启动 AVAudioEngine 失败: \(error)")
            stop()
        }
    }

    private func configureAudioSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setMode(.voiceChat)
            try session.setActive(true)
        } catch {
            print("配置音频会话失败: \(error)")
        }
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded(completion: @escaping (Bool) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()

        audioSession.requestRecordPermission { granted in
            guard granted else {
                completion(false)
                return
            }

            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:
                    completion(true)
                default:
                    completion(false)
                }
            }
        }
    }

    // MARK: - VAD & 环境噪声估计

    private func handleVADAndEnvironment(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?.pointee else { return }
        let frameLength = Int(buffer.frameLength)

        // 简单 RMS 能量估计
        var sum: Float = 0
        vDSP_measqv(channelData, 1, &sum, vDSP_Length(frameLength))
        let rms = sqrt(sum)
        let power = 20 * log10(max(rms, 0.000_000_01))

        recentPowerLevels.append(power)
        if recentPowerLevels.count > powerWindowSize {
            recentPowerLevels.removeFirst(recentPowerLevels.count - powerWindowSize)
        }

        updateEnvironmentSummary()

        // 简单 VAD：当瞬时能量高于阈值时认为用户正在说话
        let speechThreshold: Float = -30
        let speakingNow = power > speechThreshold
        DispatchQueue.main.async {
            self.isSpeaking = speakingNow
        }
    }

    private func updateEnvironmentSummary() {
        guard !recentPowerLevels.isEmpty else { return }
        let avg = recentPowerLevels.reduce(0, +) / Float(recentPowerLevels.count)

        let summary: String
        switch avg {
        case ..<(-50):
            summary = "环境非常安静"
        case -50..<(-35):
            summary = "环境较为安静"
        case -35..<(-25):
            summary = "环境有一定背景噪声"
        default:
            summary = "环境比较嘈杂，可能影响听写与对话"
        }

        DispatchQueue.main.async {
            self.environmentSummary = summary
        }
    }
}
