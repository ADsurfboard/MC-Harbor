import SwiftUI
import UIKit
import AVFoundation
import Combine

enum HarborWelcomeVoice: String, CaseIterable, Identifiable {
    case female1 = "welcome", female2 = "welcome-female2", male1 = "welcome-male", male2 = "welcome-male2"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .female1: "女声 1 · Clara"
        case .female2: "女声 2 · Clara"
        case .male1: "男声 1 · Adam"
        case .male2: "男声 2 · Morgan"
        }
    }
}

@MainActor final class HarborWelcomeAudio: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = HarborWelcomeAudio()
    static let enabledKey = "harbor.ios.welcome.enabled"
    static let voiceKey = "harbor.ios.welcome.voice"
    static let volumeKey = "harbor.ios.welcome.volume"
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var welcomed = false
    private var observation: AnyCancellable?
    private override init() {
        super.init()
        observation = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }
    func welcome() {
        guard !welcomed else { return }; welcomed = true
        guard ProcessInfo.processInfo.environment["HARBOR_SMOKE_TEST"] != "1",
              UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        play()
    }
    func play() {
        stop(); error = nil
        let voice = HarborWelcomeVoice(rawValue: UserDefaults.standard.string(forKey: Self.voiceKey) ?? "") ?? .female1
        guard let file = Bundle(for: HarborRootFactory.self).url(forResource: voice.rawValue, withExtension: "mp3") else { error = "未找到欢迎音频，请重新安装完整应用包。"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Ambient respects the silent switch and mixes with other apps.
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let audio = try AVAudioPlayer(contentsOf: file)
            guard audio.duration.isFinite, audio.duration > 0 else { throw NSError(domain: "HarborAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "欢迎音频无法解码。"]) }
            let volume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 0.65
            audio.volume = Float(min(1, max(0, volume.isFinite ? volume : 0.65))); audio.delegate = self
            audio.numberOfLoops = 0; audio.prepareToPlay(); player = audio
            guard audio.play() else { throw NSError(domain: "HarborAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "暂时无法播放音频，请稍后重试。"]) }
        } catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == id else { return }; self.stop()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player), message = error?.localizedDescription ?? "欢迎音频解码失败。"
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == id else { return }
            self.error = message; self.stop()
        }
    }
}

struct HarborWelcomeAudioSettings: View {
    @AppStorage(HarborWelcomeAudio.enabledKey) private var enabled = true
    @AppStorage(HarborWelcomeAudio.voiceKey) private var voice = HarborWelcomeVoice.female1.rawValue
    @AppStorage(HarborWelcomeAudio.volumeKey) private var volume = 0.65
    @ObservedObject private var audio = HarborWelcomeAudio.shared
    var body: some View {
        Form {
            Section {
                HarborSettingsToggle("启动时播放欢迎音频", isOn: $enabled).accessibilityIdentifier("welcome.enabled")
                Picker("声音", selection: $voice) { ForEach(HarborWelcomeVoice.allCases) { Text($0.title).tag($0.rawValue) } }
                    .pickerStyle(.menu).accessibilityIdentifier("welcome.voice")
                VStack(alignment: .leading, spacing: 10) { Text("音量"); Slider(value: $volume, in: 0...1).accessibilityLabel("欢迎音量") }
                Button { audio.play() } label: { Text("试听所选音频").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                Button { audio.stop() } label: { Text("停止试听").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                if let error = audio.error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: { Text("使用已有四份 MP3 原始素材，不以系统合成语音代替。遵循静音开关，切后台即停止；与其他应用音频混合。") }
        }.harborPageBackground().navigationTitle("欢迎音频").navigationBarTitleDisplayMode(.inline)
            .onChange(of: enabled) { if !$0 { audio.stop() } }
            .onDisappear { audio.stop() }
    }
}
