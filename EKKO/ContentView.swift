import SwiftUI
import CoreMotion
import AVFoundation
import ZIPFoundation
import Combine
import UIKit
import Accelerate

// ============================================================================
// 🎯 SECTION 1: MODÈLES DE DONNÉES
// ============================================================================

struct HighlightMoment: Identifiable, Hashable {
    let id = UUID()
    let timestamp: TimeInterval
    var song: RecognizedSong? = nil
    let peakScore: Double
}

struct RecognizedSong: Hashable {
    let title: String
    let artist: String
}

struct PartyReport: Identifiable, Codable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
    let moments: [SavedMoment]
}

struct SavedMoment: Codable, Identifiable {
    var id = UUID()
    let timestamp: TimeInterval
    let title: String
    let artist: String
}

// ============================================================================
// 📚 SECTION 2: GESTIONNAIRE D'HISTORIQUE
// ============================================================================

class HistoryManager {
    static let shared = HistoryManager()
    private let fileName = "party_history.json"
    
    func getHistoryFileURL() -> URL? {
        guard let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docPath.appendingPathComponent(fileName)
    }
    
    func saveReport(_ report: PartyReport) {
        var history = loadHistory()
        history.insert(report, at: 0)
        
        guard let url = getHistoryFileURL() else {
                    // Utilise le Singleton et le cas .fileSystem
                    ErrorManager.shared.handle(.fileSystem("history.json - URL invalide"))
                    return
                }
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: url)
            print("✅ Rapport sauvegardé")
        } catch {
            ErrorManager.shared.handle(.fileSystem("history.json - \(error.localizedDescription)"))
        }
    }
    
    func loadHistory() -> [PartyReport] {
        guard let url = getHistoryFileURL() else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: url)
            let history = try JSONDecoder().decode([PartyReport].self, from: data)
            print("✅ Historique chargé : \(history.count) rapports")
            return history
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                print("⚠️ Erreur lecture historique : \(error)")
            }
            return []
        }
    }
    
    func deleteReport(at offsets: IndexSet, from history: inout [PartyReport]) {
        history.remove(atOffsets: offsets)
        
        guard let url = getHistoryFileURL() else {
            ErrorManager.shared.handle(.fileSystem("history.json - URL invalide"))
            return
        }
        
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: url)
            print("✅ Rapport(s) supprimé(s)")
        } catch {
            ErrorManager.shared.handle(.fileSystem("history.json - \(error.localizedDescription)"))
        }
    }
}

// ============================================================================
// 📱 SECTION 3: VUE PRINCIPALE (ContentView)
// ============================================================================

struct ContentView: View {
    
    static var appVersionInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Inconnu"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Inconnu"
        return "Version \(version) (Build \(build))"
    }
    
    enum AppState { case idle, recording, analyzing, fastReport }
    @State private var currentState: AppState = .idle
    @State private var statusText: String = "Prêt à capturer la soirée."
    @State private var savedFiles: [URL] = []
    
    @StateObject private var errorManager = ErrorManager.shared
    
    @State private var history: [PartyReport] = []
    @State private var highlightMoments: [HighlightMoment] = []
    @State private var elapsedTimeString: String = "00:00:00"
    @State private var timerSubscription: AnyCancellable?
    @State private var startTime: Date?
    
    @State private var showingStartAlert = false
    @State private var showingShortSessionAlert = false
    @State private var isFastReportEnabled: Bool = true
    @State private var isAppActive: Bool = true
        
    @StateObject private var analysisManager = AnalysisManager()
    private let motionManager = MotionManager()
    private let audioRecorder = AudioRecorderManager()
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    
                    Text("EKKO")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .padding(.top, 40)
                        .foregroundColor(.white)
                    
                    HStack {
                        Image(systemName: isFastReportEnabled ? "bolt.fill" : "bolt.slash.fill")
                            .foregroundColor(isFastReportEnabled ? .yellow : .gray)
                        Text("Activer le Fast Report")
                        Spacer()
                        Toggle("", isOn: $isFastReportEnabled).labelsHidden().tint(.pink)
                    }
                    .padding().background(Color.white.opacity(0.1)).cornerRadius(10).padding(.horizontal)
                    
                    Text(audioRecorder.wasInterrupted ?
                        "⚠️ REPRENDRE L'ENREGISTREMENT : L'audio a été coupé par le système." :
                            statusText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .foregroundColor(audioRecorder.wasInterrupted ? .red : .gray)
                    
                    switch currentState {
                    case .idle:
                        IdleView(
                            history: $history,
                            savedFiles: $savedFiles,
                            deleteHistoryAction: { indexSet in HistoryManager.shared.deleteReport(at: indexSet, from: &history) },
                            deleteFileAction: deleteFiles
                        )
                    case .recording:
                        RecordingView(elapsedTimeString: $elapsedTimeString)
                    case .analyzing:
                        AnalyzingView(progress: analysisManager.analysisProgress)
                    case .fastReport:
                        FastReportView(moments: $highlightMoments, onDone: {
                            currentState = .idle
                            statusText = "Prêt pour une nouvelle soirée."
                            loadSavedFiles()
                            history = HistoryManager.shared.loadHistory()
                        })
                    }
                    
                    Text(ContentView.appVersionInfo)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.top, 5)
                    
                    if currentState == .recording || currentState == .idle {
                        Button(action: {
                            if currentState == .idle {
                                showingStartAlert = true
                            } else {
                                if let start = startTime, Date().timeIntervalSince(start) < AppConfig.Timing.minSessionDuration {
                                    showingShortSessionAlert = true
                                } else {
                                    Task { await stopAndAnalyze() }
                                }
                            }
                        }) {
                            Text(currentState == .recording ? "Terminer la Soirée" : "Démarrer la Capture")
                                .font(.title3).fontWeight(.bold)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.white)
                                .background(currentState == .recording ? AnyView(Color.red) : AnyView(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.pink]), startPoint: .leading, endPoint: .trailing)))
                                .cornerRadius(20)
                        }
                        .padding(.horizontal, 40).padding(.bottom, 20)
                    }
                }
                .onAppear {
                    loadSavedFiles()
                    history = HistoryManager.shared.loadHistory()
                }
                .preferredColorScheme(.dark)
                
                .alert("Avant de commencer", isPresented: $showingStartAlert) {
                    Button("C'est parti !", role: .cancel) { startSession() }
                } message: { Text("Verrouillez l'écran et activez le Mode Avion.") }
                
                .alert("Déjà fini ?", isPresented: $showingShortSessionAlert) {
                    Button("Continuer", role: .cancel) {}
                    Button("Arrêter sans sauvegarder", role: .destructive) { cancelSession() }
                } message: { Text("Moins de 30 secondes ? C'est trop court.") }
                .alert(errorManager.currentError?.localizedDescription ?? "Erreur",
                    isPresented: $errorManager.showError,
                    presenting: errorManager.currentError) { error in
                        // Affiche un bouton différent si l'erreur est critique
                        if error.severity == .critical {
                            Button("Quitter l'application", role: .destructive) { exit(0) }
                        } else {
                            Button("Compris") { errorManager.showError = false }
                        }
                    } message: { error in
                        if let suggestion = error.recoverySuggestion {
                            Text(suggestion)
                        }
                }
            }
            .navigationBarHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if !isAppActive { handleAppResumption() }
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppActive = false
        }
    }
    
    // --- LOGIQUE MÉTIER ---
    
    func startSession() {
        currentState = .recording
        statusText = "🔴 Enregistrement en cours..."
        savedFiles.removeAll()
        audioRecorder.startRecording()
        motionManager.startUpdates(audioRecorder: self.audioRecorder)
        startTime = Date()
        timerSubscription = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { _ in
            let diff = Date().timeIntervalSince(startTime ?? Date())
            let h = Int(diff) / 3600
            let m = Int(diff) / 60 % 60
            let s = Int(diff) % 60
            elapsedTimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }
    
    func handleAppResumption() {
        if audioRecorder.wasInterrupted {
            print("🔊 Reprise forcée.")
            audioRecorder.resumeAfterForeground()
        }
    }
    
    func stopAndAnalyze() async {
        timerSubscription?.cancel()
        let audioSegments = audioRecorder.stopRecording()
        
        guard let sensorsURL = motionManager.stopAndSaveToFile() else {
            errorManager.handle(.sensor(.dataWriteFailed))
            statusText = "❌ Erreur de sauvegarde."
            currentState = .idle
            return
        }
        
        await MainActor.run { self.statusText = "Fusion audio en cours..." }
        
        let (mergedAudioURL, validRanges) = await analysisManager.mergeAudioFiles(urls: audioSegments)
        let finalAudioURL = mergedAudioURL ?? audioSegments.first
        
        guard let validAudioURL = finalAudioURL else {
            errorManager.handle(.audio(.mergeFailed))
            statusText = "❌ Erreur Audio critique."
            currentState = .idle
            return
        }
        
        let metadataURL = motionManager.createMetadataFile(startTime: startTime ?? Date())
        var filesToZip = [validAudioURL, sensorsURL]
        if let meta = metadataURL { filesToZip.append(meta) }
        
        if isFastReportEnabled {
            await MainActor.run {
                self.currentState = .analyzing
                self.statusText = "Analyse..."
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            let rangesToUse = mergedAudioURL != nil ? validRanges : [(0.0, 100000.0)]
            
            let moments = await analysisManager.analyzeSessionComplete(
                audioURL: validAudioURL,
                sensorsURL: sensorsURL,
                validAudioRanges: rangesToUse
            )
            
            let validMoments = moments.map { SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "") }
            let finalDuration = Date().timeIntervalSince(startTime ?? Date())
            let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
            HistoryManager.shared.saveReport(report)
            
            do {
                let reportData = try JSONEncoder().encode(report)
                let tempReportURL = FileManager.default.temporaryDirectory.appendingPathComponent("report_\(Int(Date().timeIntervalSince1970)).json")
                try reportData.write(to: tempReportURL)
                filesToZip.append(tempReportURL)
            } catch {
                errorManager.handle(.fileSystem("Sauvegarde rapport JSON temporaire : \(error.localizedDescription)"))
            }
            
            await MainActor.run {
                self.highlightMoments = moments
                self.history = HistoryManager.shared.loadHistory()
                self.statusText = "Voici votre Top Kiff !"
                self.currentState = .fastReport
                
                compressAndSave(files: filesToZip)
                
                if mergedAudioURL != nil {
                    for segment in audioSegments {
                        do {
                            try FileManager.default.removeItem(at: segment)
                        } catch {
                            errorManager.logWarning("Segment non supprimé : \(segment.lastPathComponent)")
                        }
                    }
                }
            }
        } else {
            compressAndSave(files: filesToZip)
            await MainActor.run {
                self.statusText = "Sauvegardé."
                self.currentState = .idle
                self.loadSavedFiles()
                if mergedAudioURL != nil {
                    for segment in audioSegments {
                        do {
                            try FileManager.default.removeItem(at: segment)
                        } catch {
                            errorManager.logWarning("Segment non supprimé : \(segment.lastPathComponent)")
                        }
                    }
                }
            }
        }
    }

    func cancelSession() {
        timerSubscription?.cancel()
        let segs = audioRecorder.stopRecording()
        for s in segs {
            do {
                try FileManager.default.removeItem(at: s)
            } catch {
                errorManager.logWarning("Impossible de supprimer le segment : \(s.lastPathComponent)")
            }
        }
        _ = motionManager.stopAndSaveToFile()
        currentState = .idle
        statusText = "Session annulée."
    }
    
    // --- GESTION FICHIERS ZIP ---
    
    func compressAndSave(files: [URL]) {
        let fm = FileManager.default
        
        guard let firstAudioURL = files.first(where: { $0.pathExtension == "wav" || $0.pathExtension == "m4a" }) else {
            errorManager.handle(.fileSystem("ZIP : Aucun fichier audio source trouvé"))
            return
        }
        
        let originalFilename = firstAudioURL.lastPathComponent
        let prefixToFind = "rec_seg_"
        
        var startDate = Date()
        
        if let startRange = originalFilename.range(of: prefixToFind)?.upperBound,
           let endRange = originalFilename[startRange...].range(of: ".")?.lowerBound,
           let timestamp = Double(String(originalFilename[startRange..<endRange])) {
            startDate = Date(timeIntervalSince1970: timestamp)
        }
        
        let durationSeconds = Date().timeIntervalSince(startDate)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmm"
        let timePart = timeFormatter.string(from: startDate)
        let totalMinutes = Int(durationSeconds / 60.0)
        let durationString = String(format: "%dh%02dm", totalMinutes / 60, totalMinutes % 60)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let datePart = dateFormatter.string(from: startDate)
        
        let newZipName = "EKKO\(timePart)_\(datePart)_\(durationString).zip"
        
        guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            errorManager.handle(.fileSystem("ZIP : Cache inaccessible"));
            return
        }
        
        let zipURL = cachePath.appendingPathComponent(newZipName)
        
        do {
            try? fm.removeItem(at: zipURL)
            
            let archive = try Archive(url: zipURL, accessMode: .create)
            for file in files {
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
            }
            
            print("✅ ZIP créé : \(newZipName)")
            
            // Suppression des fichiers sources
            for file in files {
                do {
                    try fm.removeItem(at: file)
                } catch {
                    errorManager.logWarning("Impossible de supprimer \(file.lastPathComponent) : \(error)")
                }
            }
            
        } catch {
            errorManager.handle(.fileSystem("ZIP : \(error.localizedDescription)"))        }
        
        loadSavedFiles()
    }
    func deleteFiles(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            let fileURL = savedFiles[index]
            do {
                try fm.removeItem(at: fileURL)
                print("✅ Fichier supprimé : \(fileURL.lastPathComponent)")
            } catch {
                errorManager.handle(.fileSystem("Suppression de \(fileURL.lastPathComponent) - \(error.localizedDescription)"))            }
        }
        loadSavedFiles()
    }
    func loadSavedFiles() {
        let fm = FileManager.default
        guard let doc = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        
        self.savedFiles = (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)
                            .filter { $0.pathExtension == "zip" }
                            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })) ?? []
    }
}

// ============================================================================
// 🎨 SECTION 4: COMPOSANTS D'INTERFACE (Sous-Vues)
// ============================================================================

struct IdleView: View {
    @Binding var history: [PartyReport]
    @Binding var savedFiles: [URL]
    var deleteHistoryAction: (IndexSet) -> Void
    var deleteFileAction: (IndexSet) -> Void
    
    @State private var selectedTab = 0
    
    var body: some View {
        VStack {
            Picker("Affichage", selection: $selectedTab) {
                Text("Journal").tag(0)
                Text("Fichiers ZIP").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle()).padding()
            
            if selectedTab == 0 {
                if history.isEmpty { EmptyState(icon: "music.note.list", text: "Aucune soirée enregistrée.") }
                else {
                    List {
                        ForEach(history) { report in
                            NavigationLink(destination: HistoryDetailView(report: report)) {
                                VStack(alignment: .leading) {
                                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.headline).foregroundColor(.white)
                                    Text("\(report.moments.count) moment(s) fort(s)").font(.caption).foregroundColor(.orange)
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }
                        .onDelete(perform: deleteHistoryAction)
                    }
                    .scrollContentBackground(.hidden)
                }
            } else {
                if savedFiles.isEmpty { EmptyState(icon: "doc.zipper", text: "Aucun fichier brut.") }
                else {
                    List {
                        ForEach(savedFiles, id: \.self) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(file.lastPathComponent).font(.caption).foregroundColor(.white)
                                    Text(getFileSize(url: file)).font(.caption2).foregroundColor(.gray)
                                }
                                Spacer()
                                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }
                        .onDelete(perform: deleteFileAction)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            Spacer()
        }
    }
    
    func getFileSize(url: URL) -> String {
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attr?[.size] as? Int64 ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct EmptyState: View {
    let icon: String; let text: String
    var body: some View { VStack { Spacer(); Image(systemName: icon).font(.system(size: 50)).foregroundColor(.gray); Text(text).foregroundColor(.gray).padding(.top); Spacer() } }
}

struct RecordingView: View {
    @Binding var elapsedTimeString: String; @State private var pulse = false
    var body: some View { VStack(spacing: 30) { Spacer(); ZStack { Circle().stroke(Color.red.opacity(0.5), lineWidth: 2).frame(width: 200, height: 200).scaleEffect(pulse ? 1.2 : 1.0).opacity(pulse ? 0 : 1).onAppear { withAnimation(Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true } }; Text(elapsedTimeString).font(.system(size: 50, weight: .bold, design: .monospaced)).foregroundColor(.white) }; Text("Capture de l'ambiance...").foregroundColor(.gray); Spacer() } }
}

struct AnalyzingView: View {
    let progress: Double
    var body: some View { VStack(spacing: 20) { Spacer(); ProgressView(value: progress).progressViewStyle(LinearProgressViewStyle(tint: Color.pink)).padding(); Text("Analyse Intelligente en cours...").foregroundColor(.white); Text("\(Int(progress * 100))%").font(.caption).foregroundColor(.gray); Spacer() } }
}

struct FastReportView: View {
    @Binding var moments: [HighlightMoment]; var onDone: () -> Void
    var body: some View { VStack { Text(moments.count == 1 ? "🏆 LE MOMENT D'OR" : "🔥 TOP 5 DE LA SOIRÉE").font(.title2).bold().foregroundColor(.white).padding(.top); if moments.isEmpty { Spacer(); Text("Aucune musique reconnue 😔").foregroundColor(.gray).padding(); Spacer() } else { List { ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in HStack(spacing: 15) { ZStack { Circle().fill(index == 0 ? Color.yellow : (index == 1 ? Color.gray : Color.orange)).frame(width: 30, height: 30); Text("\(index + 1)").font(.headline).foregroundColor(.black) }; VStack(alignment: .leading) { Text(m.song?.title ?? "Inconnu").font(.headline).foregroundColor(.white); Text(m.song?.artist ?? "").font(.caption).foregroundColor(.gray) }; Spacer(); Text(formatTime(m.timestamp)).font(.system(.caption, design: .monospaced)).padding(6).background(Color.white.opacity(0.1)).cornerRadius(8).foregroundColor(.white) }.listRowBackground(Color.white.opacity(0.1)).padding(.vertical, 5) } }.listStyle(.plain) }; Button(action: { onDone() }) { Text("Sauvegarder et continuer").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.blue).cornerRadius(15) }.padding() }.background(Color.black) }
    func formatTime(_ t: TimeInterval) -> String { let h = Int(t) / 3600; let m = Int(t) / 60 % 60; if h > 0 { return "\(h)h \(m)m" } else { return "\(m) min" } }
}

struct HistoryDetailView: View {
    let report: PartyReport
    var body: some View { ZStack { Color.black.ignoresSafeArea(); List(report.moments) { m in VStack(alignment: .leading) { Text(m.title).font(.headline).foregroundColor(.white); Text(m.artist).font(.caption).foregroundColor(.gray); Text("À \(Int(m.timestamp / 60)) min \(Int(m.timestamp) % 60) s").font(.caption2).foregroundColor(.orange) }.listRowBackground(Color.white.opacity(0.1)) }.scrollContentBackground(.hidden) }.navigationTitle("Détails Soirée") }
}

// ============================================================================
// 🎤 SECTION 5: MANAGER AUDIO
// ============================================================================

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

// ============================================================================
// 📊 SECTION 6: MANAGER CAPTEURS (MotionManager)
// Description : Enregistre Mouvements + Audio + PROXIMITÉ dans un CSV.
// ============================================================================
class MotionManager {
    private let mm = CMMotionManager()
    
    // On ne garde plus TOUT l'historique, juste un petit tampon de 50 lignes (5 sec)
    private var writeBuffer: String = ""
    private var bufferCount = 0
    private let bufferLimit = AppConfig.Sensors.bufferSize
    private var fileHandle: FileHandle?
    private var fileURL: URL?

    // Pour le rapport final
    private var batteryLevelStart: Float = 0.0
    private var startTime: Date = Date()

    func startUpdates(audioRecorder: AudioRecorderManager) {
        // 1. Préparation du fichier
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = doc.appendingPathComponent("sensors_\(Int(Date().timeIntervalSince1970)).csv")
        
        // 2. En-tête CSV
        let header = "timestamp,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,attitude_roll,attitude_pitch,attitude_yaw,gravity_x,gravity_y,gravity_z,audio_power_db,proximity\n"
        
        guard let url = fileURL else { return }
        
        // 3. Ouverture du "tuyau" vers le fichier (FileHandle)
        do {
            // On écrit l'en-tête (crée le fichier)
            try header.write(to: url, atomically: true, encoding: .utf8)
            // On ouvre le robinet pour ajouter des données à la suite
            self.fileHandle = try FileHandle(forWritingTo: url)
            self.fileHandle?.seekToEndOfFile()
        } catch {
            ErrorManager.shared.handle(.sensor(.criticalFileSetup))
            return
        }

        // 4. Initialisation Capteurs
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.batteryLevelStart = UIDevice.current.batteryLevel
        self.startTime = Date()
        
        // Activation Proximité
        UIDevice.current.isProximityMonitoringEnabled = true
        
        mm.deviceMotionUpdateInterval = AppConfig.Sensors.updateInterval
        
        mm.startDeviceMotionUpdates(to: .main) { [weak self] (deviceMotion, error) in
            guard let self = self, let data = deviceMotion else { return }
            
            let audioPower = audioRecorder.getCurrentPower()
            let timestamp = Date().timeIntervalSince1970
            let proximity = UIDevice.current.proximityState ? 1 : 0
            
            // 5. Création de la ligne
            let line = "\(timestamp),\(data.userAcceleration.x),\(data.userAcceleration.y),\(data.userAcceleration.z),\(data.rotationRate.x),\(data.rotationRate.y),\(data.rotationRate.z),\(data.attitude.roll),\(data.attitude.pitch),\(data.attitude.yaw),\(data.gravity.x),\(data.gravity.y),\(data.gravity.z),\(audioPower),\(proximity)\n"
            
            // 6. Ajout au petit tampon
            self.writeBuffer.append(line)
            self.bufferCount += 1
            
            // 7. Flush sur le disque tous les 50 échantillons (5 secondes)
            if self.bufferCount >= self.bufferLimit {
                self.flushToDisk()
            }
        }
    }
    
    // Fonction privée pour vider le tampon
    private func flushToDisk() {
        if let data = writeBuffer.data(using: .utf8) {
            // Écriture physique
            try? fileHandle?.write(contentsOf: data)
        }
        // Reset du tampon
        writeBuffer = ""
        bufferCount = 0
    }
    
    func stopAndSaveToFile() -> URL? {
        mm.stopDeviceMotionUpdates()
        UIDevice.current.isProximityMonitoringEnabled = false
        
        // 8. IMPORTANT : Écrire ce qui reste dans le tampon avant de fermer
        flushToDisk()
        
        // Fermeture propre du fichier
        try? fileHandle?.close()
        fileHandle = nil
        
        return fileURL
    }
    
    // REMPLACER LA FONCTION createMetadataFile EXISTANTE PAR CELLE-CI :
    func createMetadataFile(startTime: Date) -> URL? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        let metadataContent = """
        METADATA EKKO
        ------------------
        App Version: \(ContentView.appVersionInfo)
        Date: \(Date())
        Début Session: \(startTime)
        Fin Session: \(endTime)
        Durée: \(String(format: "%.2f", duration / 60)) min
        Batterie Début: \(self.batteryLevelStart * 100)%
        Batterie Fin: \(UIDevice.current.batteryLevel * 100)%
        """
        
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let metadataURL = docPath.appendingPathComponent("metadata_\(Int(Date().timeIntervalSince1970)).txt")
            
            do {
                try metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8)
                return metadataURL
            } catch {
                ErrorManager.shared.handle(.fileSystem("Création metadata : \(error.localizedDescription)"))
                return nil
            }
        }
}

// ============================================================================
// 🧠 SECTION 7: MANAGER ANALYSE (CORRIGÉE)
// ============================================================================

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

#Preview {
    ContentView()
}
