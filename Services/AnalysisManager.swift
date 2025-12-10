// ============================================================================
// 🧠 MANAGER ANALYSE
// ============================================================================

import Foundation
import AVFoundation

@MainActor
class AnalysisManager: NSObject, ObservableObject {
    let acrClient: ACRCloudRecognition
    @Published var analysisProgress: Double = 0.0
    
    override init() {
        let config = ACRCloudConfig()
        let info = Bundle.main.infoDictionary
        config.host = info?["ACRHost"] as? String ?? ""
        config.accessKey = info?["ACRAccessKey"] as? String ?? ""
        config.accessSecret = info?["ACRSecret"] as? String ?? ""
        
        config.recMode = rec_mode_remote
        config.requestTimeout = Int(AppConfig.API.requestTimeout)
        config.protocol = "https"
        self.acrClient = ACRCloudRecognition(config: config)
    }
    
    // --- FUSION AUDIO ---
    func mergeAudioFiles(urls: [URL]) async -> (URL?, [(start: Double, end: Double)]) {
        guard !urls.isEmpty else { return (nil, []) }
        if urls.count == 1 {
            let asset = AVURLAsset(url: urls.first!)
            let duration: CMTime = (try? await asset.load(.duration)) ?? .zero
            return (urls.first, [(0, duration.seconds)])
        }
        
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return (nil, []) }
        
        let sortedURLs = urls.sorted { (extractTimestamp(from: $0) ?? 0) < (extractTimestamp(from: $1) ?? 0) }
        guard let firstFile = sortedURLs.first, let startTimeBase = extractTimestamp(from: firstFile) else { return (nil, []) }
        
        var validRanges: [(start: Double, end: Double)] = []
        
        for url in sortedURLs {
            let asset = AVURLAsset(url: url)
            do {
                let tracks: [AVAssetTrack] = try await asset.load(.tracks)
                guard let track = tracks.first else { continue }
                let duration: CMTime = try await asset.load(.duration)
                guard let fileTimestamp = extractTimestamp(from: url) else { continue }
                
                let timeOffset = fileTimestamp - startTimeBase
                let insertTime = CMTime(seconds: timeOffset, preferredTimescale: 44100)
                try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: insertTime)
                validRanges.append((start: timeOffset, end: timeOffset + duration.seconds))
            } catch { print("⚠️ Erreur fusion: \(error)") }
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("merged_session_\(Int(Date().timeIntervalSince1970)).m4a")
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return (nil, []) }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        await exportSession.export()
        
        return exportSession.status == .completed ? (outputURL, validRanges) : (nil, [])
    }
    
    private func extractTimestamp(from url: URL) -> Double? {
        let filename = url.lastPathComponent.replacingOccurrences(of: ".wav", with: "")
        let components = filename.components(separatedBy: "_")
        if let last = components.last, let ts = Double(last) { return ts }
        return nil
    }
    
    // --- ANALYSE PRINCIPALE ---
    func analyzeSessionComplete(audioURL: URL, sensorsURL: URL, validAudioRanges: [(start: Double, end: Double)]) async -> [HighlightMoment] {
        
        guard FileManager.default.fileExists(atPath: audioURL.path),
              FileManager.default.fileExists(atPath: sensorsURL.path) else { return [] }
        
        let asset = AVURLAsset(url: audioURL)
        let totalDuration = (try? await asset.load(.duration).seconds) ?? 0.0
        
        // 1. RECHERCHE DES PICS (Avec ta formule PartyPower sur 20s)
        let candidates = findSmartPeaks(csvURL: sensorsURL, validAudioRanges: validAudioRanges)
        print("🔍 \(candidates.count) moments 'PartyPower' identifiés.")
        
        var recognizedMoments: [HighlightMoment] = []
        let total = Double(candidates.count)
        
        // 2. RECONNAISSANCE ACRCLOUD
        for (index, candidate) in candidates.enumerated() {
            await MainActor.run { self.analysisProgress = Double(index) / max(total, 1.0) }
            
            let timestamp = candidate.t
            let score = candidate.score // C'est ton PartyPower moyen
            // On extrait 20 secondes
            if let chunk = await extractAudioChunk(asset: asset, at: timestamp, duration: AppConfig.Timing.analysisWindowSeconds) {                if let resultJSON = acrClient.recognize(chunk) {
                if let song = parseResult(resultJSON) {
                    recognizedMoments.append(HighlightMoment(timestamp: timestamp, song: song, peakScore: score))
                    print("✅ Musique trouvée : \(song.title) (Score: \(Int(score)))")
                } else {
                    print("⚠️ Musique non reconnue à \(Int(timestamp))s")
                }
            }
            }
        }
        
        await MainActor.run { self.analysisProgress = 1.0 }
        return filterMomentsSmartly(moments: recognizedMoments, totalDuration: totalDuration)
    }
    
    private func extractAudioChunk(asset: AVURLAsset, at time: TimeInterval, duration: Double) async -> Data? {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let startTime = CMTime(seconds: max(0, time), preferredTimescale: 44100)
        let durationTime = CMTime(seconds: duration, preferredTimescale: 44100) // Sera 20s maintenant
        exportSession.outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("chunk_\(UUID().uuidString).m4a")
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: startTime, duration: durationTime)
        await exportSession.export()
        
        if exportSession.status == .completed, let url = exportSession.outputURL {
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            return data
        }
        return nil
    }
    
    // --- ALGORITHME PARTY POWER ---
    private func findSmartPeaks(csvURL: URL, validAudioRanges: [(start: Double, end: Double)]) -> [(t: Double, score: Double)] {
        guard let reader = StreamReader(path: csvURL.path) else { return [] }
        
        var data: [(t: Double, power: Double)] = []
        var previousYaw: Double? = nil
        
        _ = reader.nextLine()
        
        for row in reader {
            let cols = row.components(separatedBy: ",")
            if cols.count >= 10,
               let t = Double(cols[0]),
               let ax = Double(cols[1]), let ay = Double(cols[2]), let az = Double(cols[3]),
               let gx = Double(cols[4]), let gy = Double(cols[5]), let gz = Double(cols[6]),
               let yaw = Double(cols[9]) {
                
                let accelMag = sqrt(ax*ax + ay*ay + az*az)
                let gyroMag = sqrt(gx*gx + gy*gy + gz*gz)
                
                var yawChange = 0.0
                if let prev = previousYaw {
                    yawChange = abs(yaw - prev)
                    // Remplace > 3.0
                    if yawChange > AppConfig.Algo.yawChangeThreshold { yawChange = 0.0 }
                }
                previousYaw = yaw
                
                // Remplace * 15.0 et * 50.0
                let rawPartyPower = accelMag + (gyroMag * AppConfig.Algo.gyroWeight) + (yawChange * AppConfig.Algo.yawWeight)
                data.append((t, rawPartyPower))
            }
        }
        reader.close()
        
        guard !data.isEmpty else { return [] }
        
        let windowSize = AppConfig.Algo.windowSizeInLines
        let strideStep = AppConfig.Algo.strideInLines
        
        var windows: [(t: Double, score: Double)] = []
        let startTime = data[0].t
        
        if data.count > windowSize {
            for i in stride(from: 0, to: data.count - windowSize, by: strideStep) {
                let chunk = data[i..<i+windowSize]
                let avgPower = chunk.map { $0.power }.reduce(0, +) / Double(chunk.count)
                
                if let first = chunk.first {
                    let relativeTime = first.t - startTime
                    if avgPower > AppConfig.Algo.minScoreThreshold {
                        windows.append((t: relativeTime, score: avgPower))
                    }
                }
            }
        }
        
        let sortedWindows = windows.sorted { $0.score > $1.score }
        var selectedPeaks: [(t: Double, score: Double)] = []
        
        for window in sortedWindows {
            if selectedPeaks.count >= AppConfig.Ranking.initialCandidatesLimit { break }

            let isTooClose = selectedPeaks.contains { abs($0.t - window.t) < AppConfig.Timing.minTimeBetweenPeaks }
            if !isTooClose {
                selectedPeaks.append(window)
            }
        }
        
        return selectedPeaks.sorted(by: { $0.t < $1.t })
    }
    private func filterMomentsSmartly(moments: [HighlightMoment], totalDuration: TimeInterval) -> [HighlightMoment] {
            
            // 1. On demande à la Config combien on en veut (1, 3 ou 5 ?)
            let targetCount = AppConfig.Ranking.getTargetCount(for: totalDuration)
            
            // 2. On trie par score décroissant (les meilleurs en premier)
            let rankedMoments = moments.sorted { $0.peakScore > $1.peakScore }
            
            var validMoments: [HighlightMoment] = []
            
            // 3. On remplit la liste en évitant les doublons de chansons
            for candidate in rankedMoments {
                let isDuplicate = validMoments.contains { valid in
                    // On vérifie si c'est la même chanson (Titre + Artiste)
                    return valid.song?.title == candidate.song?.title
                }
                
                if !isDuplicate {
                    validMoments.append(candidate)
                }
                
                // 4. On s'arrête dès qu'on a atteint le chiffre cible (1, 3 ou 5)
                if validMoments.count >= targetCount { break }
            }
            
            // On renvoie la liste triée par score
            return validMoments.sorted { $0.peakScore > $1.peakScore }
        }
    
    private func parseResult(_ jsonString: String?) -> RecognizedSong? {
        guard let str = jsonString, let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any],
              let music = (metadata["music"] as? [[String: Any]])?.first else { return nil }
        
        let title = music["title"] as? String ?? "Inconnu"
        let artists = (music["artists"] as? [[String: String]])?.compactMap { $0["name"] }.joined(separator: ", ") ?? ""
        return RecognizedSong(title: title, artist: artists)
    }
}

