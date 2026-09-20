import AVFoundation

/// Speaks navigation announcements through `SpeechGate`: no repeats, important messages cut in,
/// milestones never pile up, and a message that had to wait is dropped if it went stale
/// ("前方 50 公尺" read out after the turn helps nobody).
@MainActor
final class NavSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var gate = SpeechGate()
    private var pending: (text: String, priority: SpeechPriority, at: Date)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, _ priority: SpeechPriority = .normal) {
        let now = Date()
        switch gate.decide(text, priority: priority, now: now) {
        case .speakNow:
            utter(text)
        case .interruptThenSpeak:
            pending = nil
            synthesizer.stopSpeaking(at: .word)
            utter(text)
        case .queueLatest:
            pending = (text, priority, now)
        case .skip:
            break
        }
    }

    func stop() {
        pending = nil
        synthesizer.stopSpeaking(at: .immediate)
        gate.finished()
    }

    private func utter(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95      // a touch slower than default: easier to catch while driving
        u.preUtteranceDelay = 0.1
        u.postUtteranceDelay = 0.4
        synthesizer.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didFinishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // An interrupt starts its replacement immediately — do not mark idle or drop what is queued.
    }

    private func didFinishSpeaking() {
        gate.finished()
        guard let p = pending else { return }
        pending = nil
        let now = Date()
        guard now.timeIntervalSince(p.at) < SpeechGate.queueMaxAge else { return }
        gate.markSpoken(p.text, p.priority, now)
        utter(p.text)
    }
}
