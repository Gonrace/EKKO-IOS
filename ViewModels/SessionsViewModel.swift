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
    
    // NOTE: highlightMoments sert de tampon après analyse (avant conversion en SavedMoment)
    @Published var highlightMoments: [HighlightMoment] = []
    
    // 🔥 Le rapport final complet pour l'affichage FastReportView
    @Published var fastReportInstance: FastReport? = nil
    
    // L'historique stocke les rapports FastReport
    @Published var history: [FastReport] = []
    
    @Published var savedFiles: [URL] = []
    
    // MARK: - Services (Les Managers)
    private let audioRecorder = AudioRecorderManager()
    private let motionManager = MotionManager()
    private let analysisManager = AnalysisManager()
    
    // MARK: - Logique Interne
    private var timerSubscription: AnyCancellable?
    var startTime: Date?
    private var audioSegments: [URL] = []
    
    // MARK: - Initialisation
    init() {
        refreshData()
    }
    
    func refreshData() {
        // NOTE: Assurez-vous que HistoryManager.shared.loadHistory() retourne bien [FastReport]
        self.history = HistoryManager.shared.loadHistory()
        self.savedFiles = StorageManager.shared.loadSavedFiles()
    }
    
    // MARK: - Actions Utilisateur
    
    func startSession() {
        self.state = .recording
        self.statusText = "🔴 Enregistrement en cours..."
        self.startTime = Date()
        
        audioRecorder.startRecording()
        motionManager.startUpdates(audioRecorder: audioRecorder)
        
        startTimer()
    }
    
    func stopAndAnalyze(isFastReportEnabled: Bool) async {
        // 1. Arrêt des capteurs et timer
        stopTimer()
        self.audioSegments = audioRecorder.stopRecording()
        
        guard let sensorsURL = motionManager.stopAndSaveToFile() else {
            ErrorManager.shared.handle(.sensor(.dataWriteFailed))
            resetToIdle()
            return
        }
        
        self.state = .analyzing
        self.statusText = "Fusion et analyse audio en cours..."
        
        // 2. Fusion Audio
        let (mergedAudioURL, validRanges) = await analysisManager.mergeAudioFiles(urls: audioSegments)
        let finalAudioURL = mergedAudioURL ?? audioSegments.first
        
        guard let validAudioURL = finalAudioURL else {
            ErrorManager.shared.handle(.audio(.mergeFailed))
            resetToIdle()
            return
        }
        
        // 3. Analyse lourde
        let rangesToUse = mergedAudioURL != nil ? validRanges : [(0.0, 100000.0)]
        let moments = await analysisManager.analyzeSessionComplete(
            audioURL: validAudioURL,
            sensorsURL: sensorsURL,
            validAudioRanges: rangesToUse
        )
        
        // 4. CRÉATION DU RAPPORT COMPLET (Utilisé pour sauvegarde et affichage)
        let finalDuration = Date().timeIntervalSince(startTime ?? Date())
        let healthStatus = analysisManager.getAudioHealthStatus(moments: moments)
        
        // Conversion des HighlightMoment (en direct) en SavedMoment (sauvegardé)
        let savedMoments = moments.map { moment in
            SavedMoment(
                timestamp: moment.timestamp,
                title: moment.song?.title ?? "Inconnu",
                artist: moment.song?.artist ?? "",
                userBPM: moment.userBPM,
                musicBPM: moment.musicBPM,
                averagedB: moment.averagedB
            )
        }
        
        let generatedReport = FastReport(
            id: UUID(),
            date: Date(),
            duration: finalDuration,
            moments: savedMoments,
            audioHealthStatus: healthStatus
        )
        
        // 5. Sauvegarde des données et gestion du FastReport
        self.saveToHistory(report: generatedReport) // Sauvegarde du rapport dans l'historique
        
        // Préparation des fichiers pour le ZIP
        let metadataURL = motionManager.createMetadataFile(startTime: startTime ?? Date())
        var filesToZip = [validAudioURL, sensorsURL]
        if let meta = metadataURL { filesToZip.append(meta) }
        
        if isFastReportEnabled {
            // Crée le JSON temporaire pour le ZIP
            if let reportJSON = createTempReportJSON(report: generatedReport) {
                filesToZip.append(reportJSON)
            }
            
            // Finalisation du ZIP
            finishSession(filesToZip: filesToZip, audioSegmentsToDelete: audioSegments)
            
            // Affichage Résultats
            self.fastReportInstance = generatedReport // Stocke le rapport pour l'affichage
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
        self.fastReportInstance = nil // Nettoyage de l'instance du rapport
        refreshData()
    }
    
    // MARK: - Méthodes Privées (Helpers)
    
    private func finishSession(filesToZip: [URL], audioSegmentsToDelete: [URL]) {
        // Création du ZIP via le StorageManager
        StorageManager.shared.compressAndSave(files: filesToZip) {
            // Callback optionnel si besoin
        }
        
        // Nettoyage des segments WAV d'origine
        for segment in audioSegmentsToDelete {
            do {
                try FileManager.default.removeItem(at: segment)
            } catch {
                ErrorManager.shared.logWarning("Segment non supprimé : \(segment.lastPathComponent)")
            }
        }
        
        refreshData()
    }
    
    // 🔥 CORRECTION : Sauvegarde dans l'historique (FastReport)
    private func saveToHistory(report: FastReport) {
        // NOTE : Assurez-vous que HistoryManager.shared.saveReport accepte FastReport
        HistoryManager.shared.saveReport(report)
        self.refreshData()
    }
    
    // 🔥 NOUVEAU : Crée le JSON à partir de l'instance de FastReport pour le ZIP
    private func createTempReportJSON(report: FastReport) -> URL? {
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
