import SwiftUI
import Combine
import AVFoundation

enum AppState {
    case idle
    case recording
    case analyzing
    case fastReport
}

@MainActor
class SessionViewModel: ObservableObject {
    
    // MARK: - Variables Observées par la Vue (UI)
    @Published var state: AppState = .idle
    @Published var statusText: String = "Prêt à capturer la soirée."
    @Published var elapsedTimeString: String = "00:00:00"
    @Published var highlightMoments: [HighlightMoment] = []
    
    // Pour l'accès aux données depuis la vue
    @Published var history: [PartyReport] = []
    @Published var savedFiles: [URL] = []
    
    // MARK: - Services (Les Managers)
    private let audioRecorder = AudioRecorderManager()
    private let motionManager = MotionManager()
    private let analysisManager = AnalysisManager()
    
    // MARK: - Logique Interne
    private var timerSubscription: AnyCancellable?
    var startTime: Date? // Public pour que la Vue puisse vérifier la durée
    private var audioSegments: [URL] = []
    
    // MARK: - Initialisation
    init() {
        // On charge les données au démarrage
        refreshData()
    }
    
    func refreshData() {
        self.history = HistoryManager.shared.loadHistory()
        self.savedFiles = StorageManager.shared.loadSavedFiles()
    }
    
    // MARK: - Actions Utilisateur
    
    func startSession() {
        // 1. Mise à jour de l'état
        self.state = .recording
        self.statusText = "🔴 Enregistrement en cours..."
        self.startTime = Date()
        
        // 2. Démarrage des Services
        audioRecorder.startRecording()
        motionManager.startUpdates(audioRecorder: audioRecorder)
        
        // 3. Lancement du Timer
        startTimer()
    }
    
    func stopAndAnalyze(isFastReportEnabled: Bool) async {
        // 1. Arrêt du Timer et des capteurs
        stopTimer()
        self.audioSegments = audioRecorder.stopRecording()
        
        guard let sensorsURL = motionManager.stopAndSaveToFile() else {
            ErrorManager.shared.handle(.sensor(.dataWriteFailed))
            resetToIdle()
            return
        }
        
        // 2. Mise à jour UI
        self.state = .analyzing
        self.statusText = "Fusion audio en cours..."
        
        // 3. Fusion Audio
        let (mergedAudioURL, validRanges) = await analysisManager.mergeAudioFiles(urls: audioSegments)
        let finalAudioURL = mergedAudioURL ?? audioSegments.first
        
        guard let validAudioURL = finalAudioURL else {
            ErrorManager.shared.handle(.audio(.mergeFailed))
            resetToIdle()
            return
        }
        
        // 4. Préparation des fichiers pour le ZIP
        let metadataURL = motionManager.createMetadataFile(startTime: startTime ?? Date())
        var filesToZip = [validAudioURL, sensorsURL]
        if let meta = metadataURL { filesToZip.append(meta) }
        
        // 5. Branchement Logique
        if isFastReportEnabled {
            self.statusText = "Analyse..."
            
            // Si pas de fusion, on analyse tout (fallback)
            let rangesToUse = mergedAudioURL != nil ? validRanges : [(0.0, 100000.0)]
            
            // Appel de l'analyse lourde
            let moments = await analysisManager.analyzeSessionComplete(
                audioURL: validAudioURL,
                sensorsURL: sensorsURL,
                validAudioRanges: rangesToUse
            )
            
            // Sauvegarde Historique
            saveToHistory(moments: moments)
            
            // Sauvegarde Rapport JSON temporaire pour le ZIP
            if let reportJSON = createTempReportJSON(moments: moments) {
                filesToZip.append(reportJSON)
            }
            
            // Finalisation
            finishSession(filesToZip: filesToZip, audioSegmentsToDelete: audioSegments)
            
            // Affichage Résultats
            self.highlightMoments = moments
            self.statusText = "Voici votre Top Kiff !"
            self.state = .fastReport
            
        } else {
            // Mode "Raw Data Only"
            finishSession(filesToZip: filesToZip, audioSegmentsToDelete: audioSegments)
            self.statusText = "Sauvegardé."
            self.resetToIdle()
        }
    }
    
    func cancelSession() {
        stopTimer()
        let segs = audioRecorder.stopRecording()
        
        // Nettoyage des fichiers temporaires
        for url in segs { try? FileManager.default.removeItem(at: url) }
        _ = motionManager.stopAndSaveToFile()
        
        self.statusText = "Session annulée."
        self.state = .idle
    }
    
    func resetToIdle() {
        self.state = .idle
        self.statusText = "Prêt à capturer la soirée."
        self.elapsedTimeString = "00:00:00"
        refreshData()
    }
    
    // MARK: - Méthodes Privées (Helpers)
    
    private func finishSession(filesToZip: [URL], audioSegmentsToDelete: [URL]) {
        // Création du ZIP via le StorageManager
        StorageManager.shared.compressAndSave(files: filesToZip) {
            // Callback optionnel si besoin
        }
        
        // Nettoyage des segments WAV d'origine pour ne pas encombrer
        for segment in audioSegmentsToDelete {
            do {
                try FileManager.default.removeItem(at: segment)
            } catch {
                ErrorManager.shared.logWarning("Segment non supprimé : \(segment.lastPathComponent)")
            }
        }
        
        // Rechargement des fichiers affichés
        refreshData()
    }
    
    private func saveToHistory(moments: [HighlightMoment]) {
        let validMoments = moments.map { SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "") }
        let finalDuration = Date().timeIntervalSince(startTime ?? Date())
        let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
        HistoryManager.shared.saveReport(report)
        refreshData()
    }
    
    private func createTempReportJSON(moments: [HighlightMoment]) -> URL? {
        // On recrée un petit rapport juste pour le JSON
        let validMoments = moments.map { SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "") }
        let finalDuration = Date().timeIntervalSince(startTime ?? Date())
        let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
        
        do {
            let data = try JSONEncoder().encode(report)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("report_\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url)
            return url
        } catch {
            ErrorManager.shared.handle(.fileSystem("Erreur JSON temp : \(error.localizedDescription)"))
            return nil
        }
    }
    
    private func startTimer() {
        timerSubscription = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let diff = Date().timeIntervalSince(start)
            let h = Int(diff) / 3600
            let m = Int(diff) / 60 % 60
            let s = Int(diff) % 60
            self.elapsedTimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }
    
    private func stopTimer() {
        timerSubscription?.cancel()
        timerSubscription = nil
    }
}
