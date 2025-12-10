// ============================================================================
// 🎤 MANAGER AUDIO
// ============================================================================

import Foundation
import AVFoundation
import UIKit

class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {
    var audioRecorder: AVAudioRecorder?
    var recordedFileUrls: [URL] = []
    var wasInterrupted = false
    
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    
    private func setupAndStartNewRecorder() -> URL? {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        try? session.setActive(true)
        
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "rec_seg_\(Int(Date().timeIntervalSince1970)).wav"
        let newURL = docPath.appendingPathComponent(filename)
        
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false]
        
        do {
            audioRecorder = try AVAudioRecorder(url: newURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            self.recordedFileUrls.append(newURL)
            print("✅ Nouvelle session audio: \(filename)")
            return newURL
        } catch {
            ErrorManager.shared.handle(.audio(.recordingFailed(underlying: error)))
            return nil
        }
    }
    
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo, let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            self.wasInterrupted = true
            audioRecorder?.stop()
        case .ended:
            break
        @unknown default: break
        }
    }
    
    func startRecording() {
        self.recordedFileUrls.removeAll()
        _ = setupAndStartNewRecorder()
    }
    
    func resumeAfterForeground() {
        if self.wasInterrupted {
            _ = setupAndStartNewRecorder()
            self.wasInterrupted = false
        }
    }
    
    func stopRecording() -> [URL] {
        audioRecorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        let all = self.recordedFileUrls
        self.recordedFileUrls.removeAll()
        return all
    }
    
    func getCurrentPower() -> Float {
        audioRecorder?.updateMeters()
        return audioRecorder?.averagePower(forChannel: 0) ?? -160.0
    }
}

