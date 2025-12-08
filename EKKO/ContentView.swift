import SwiftUI
import CoreMotion
import AVFoundation
import ZIPFoundation
import Combine

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
        guard let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docPath.appendingPathComponent(fileName)
    }
    
    func saveReport(_ report: PartyReport) {
        var history = loadHistory()
        history.insert(report, at: 0)
        guard let url = getHistoryFileURL(), let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url)
    }
    
    func loadHistory() -> [PartyReport] {
        guard let url = getHistoryFileURL(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PartyReport].self, from: data)) ?? []
    }
    
    func deleteReport(at offsets: IndexSet, from history: inout [PartyReport]) {
        history.remove(atOffsets: offsets)
        guard let url = getHistoryFileURL(), let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url)
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
                                if let start = startTime, Date().timeIntervalSince(start) < 30 {
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
                statusText = "❌ Erreur de sauvegarde."
                currentState = .idle
                return
            }
            
            await MainActor.run { self.statusText = "Fusion audio en cours..." }
            
            // --- MODIFICATION : Récupérer le tuple (URL, Plages) ---
            let (mergedAudioURL, validRanges) = await analysisManager.mergeAudioFiles(urls: audioSegments)
            let finalAudioURL = mergedAudioURL ?? audioSegments.first
            
            guard let validAudioURL = finalAudioURL else {
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
                
                // --- MODIFICATION : Passer les plages valides ---
                // Si mergedAudioURL est nil (échec fusion), on suppose que tout le fichier est valide (fallback)
                let rangesToUse = mergedAudioURL != nil ? validRanges : [(0.0, 100000.0)]
                
                let moments = await analysisManager.analyzeSessionComplete(audioURL: validAudioURL, sensorsURL: sensorsURL, validAudioRanges: rangesToUse)
                
                let validMoments = moments.map { SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "") }
                let finalDuration = Date().timeIntervalSince(startTime ?? Date())
                let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
                HistoryManager.shared.saveReport(report)
                
                if let reportData = try? JSONEncoder().encode(report) {
                    let tempReportURL = FileManager.default.temporaryDirectory.appendingPathComponent("report_\(Int(Date().timeIntervalSince1970)).json")
                    try? reportData.write(to: tempReportURL)
                    filesToZip.append(tempReportURL)
                }
                
                await MainActor.run {
                    self.highlightMoments = moments
                    self.history = HistoryManager.shared.loadHistory()
                    self.statusText = "Voici votre Top Kiff !"
                    self.currentState = .fastReport
                    
                    compressAndSave(files: filesToZip)
                    
                    if mergedAudioURL != nil {
                        for segment in audioSegments { try? FileManager.default.removeItem(at: segment) }
                    }
                }
            } else {
                compressAndSave(files: filesToZip)
                await MainActor.run {
                    self.statusText = "Sauvegardé."
                    self.currentState = .idle
                    self.loadSavedFiles()
                    if mergedAudioURL != nil {
                        for segment in audioSegments { try? FileManager.default.removeItem(at: segment) }
                    }
                }
            }
        }
    func cancelSession() {
        timerSubscription?.cancel()
        let segs = audioRecorder.stopRecording()
        for s in segs { try? FileManager.default.removeItem(at: s) }
        _ = motionManager.stopAndSaveToFile()
        currentState = .idle
        statusText = "Session annulée."
    }
    
    // --- GESTION FICHIERS ZIP & TAGS ---
    
    func compressAndSave(files: [URL]) {
        let fm = FileManager.default
        // On cherche le fichier audio principal
        guard let firstAudioURL = files.first(where: { $0.pathExtension == "wav" || $0.pathExtension == "m4a" }) else { return }
        
        // CORRECTION ICI : On utilise Double() pour le parsing du timestamp
        let originalFilename = firstAudioURL.lastPathComponent
        let prefixToFind = "rec_seg_"
        
        var startDate = Date()
        // Tentative de parsing de la date depuis le nom du fichier
        if let startRange = originalFilename.range(of: prefixToFind)?.upperBound,
           let endRange = originalFilename[startRange...].range(of: ".")?.lowerBound,
           let timestamp = Double(String(originalFilename[startRange..<endRange])) { // CORRECTION: Double au lieu de TimeInterval
            startDate = Date(timeIntervalSince1970: timestamp)
        } else {
            // Si le parsing échoue (ex: fichier merged), on utilise la date actuelle
            startDate = Date()
        }
        
        let durationSeconds = Date().timeIntervalSince(startDate)
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "HHmm"
        let timePart = timeFormatter.string(from: startDate)
        let totalMinutes = Int(durationSeconds / 60.0)
        let durationString = String(format: "%dh%02dm", totalMinutes / 60, totalMinutes % 60)
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyyMMdd"
        let datePart = dateFormatter.string(from: startDate)
        
        let newZipName = "EKKO\(timePart)_\(datePart)_\(durationString).zip"
        
        guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let zipURL = cachePath.appendingPathComponent(newZipName)
        try? fm.removeItem(at: zipURL)
        
        do {
            let archive = try Archive(url: zipURL, accessMode: .create)
            for file in files {
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
            }
            print("✅ ZIP créé : \(newZipName)")
            for file in files { try fm.removeItem(at: file) }
        } catch {
            print("❌ Erreur Zip: \(error)")
        }
        loadSavedFiles()
    }
    
    func deleteFiles(at offsets: IndexSet) {
        let fm = FileManager.default
        offsets.map { savedFiles[$0] }.forEach { try? fm.removeItem(at: $0) }
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
            print("❌ Erreur REC: \(error)")
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
    private var dataBuffer: [String] = []
    private var csvString = ""
    private var batteryLevelStart: Float = 0.0
    private var startTime: Date = Date()
    private var fileURL: URL?

    func startUpdates(audioRecorder: AudioRecorderManager) {
        // 1. MISE A JOUR DU HEADER CSV : Ajout de la colonne ",proximity" à la fin
        csvString = "timestamp,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,attitude_roll,attitude_pitch,attitude_yaw,gravity_x,gravity_y,gravity_z,audio_power_db,proximity\n"
        dataBuffer.removeAll()
        
        // 2. ACTIVATION DU CAPTEUR DE PROXIMITÉ
        UIDevice.current.isProximityMonitoringEnabled = true
        
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.batteryLevelStart = UIDevice.current.batteryLevel
        self.startTime = Date()
        
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = doc.appendingPathComponent("sensors_\(Int(Date().timeIntervalSince1970)).csv")
        
        mm.deviceMotionUpdateInterval = 0.1
        mm.startDeviceMotionUpdates(to: .main) { (deviceMotion, error) in
            guard let data = deviceMotion else { return }
            
            let audioPower = audioRecorder.getCurrentPower()
            let timestamp = Date().timeIntervalSince1970
            
            // 3. LECTURE DE LA PROXIMITÉ
            // Convertit le Booléen en Entier : 1 = Proche (Poche/Caché), 0 = Loin (Main/Visible)
            let proximityState = UIDevice.current.proximityState ? 1 : 0
            
            // Ajout de la variable à la fin de la ligne
            let newLine = "\(timestamp),\(data.userAcceleration.x),\(data.userAcceleration.y),\(data.userAcceleration.z),\(data.rotationRate.x),\(data.rotationRate.y),\(data.rotationRate.z),\(data.attitude.roll),\(data.attitude.pitch),\(data.attitude.yaw),\(data.gravity.x),\(data.gravity.y),\(data.gravity.z),\(audioPower),\(proximityState)\n"
            
            self.dataBuffer.append(newLine)
        }
    }
    
    func stopAndSaveToFile() -> URL? {
        mm.stopDeviceMotionUpdates()
        
        // 4. DÉSACTIVATION DU CAPTEUR (Pour économiser la batterie)
        UIDevice.current.isProximityMonitoringEnabled = false
        
        // Écriture finale
        csvString.append(contentsOf: dataBuffer.joined())
        dataBuffer.removeAll()
        
        guard let url = fileURL else { return nil }
        try? csvString.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
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
        try? metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8)
        return metadataURL
    }
}

// ============================================================================
// 🧠 SECTION 7: MANAGER ANALYSE
// ============================================================================

@MainActor
class AnalysisManager: NSObject, ObservableObject {
    let acrClient: ACRCloudRecognition
    @Published var analysisProgress: Double = 0.0
    
    override init() {
        let config = ACRCloudConfig()
        // --- VOS CLES ---
        config.host = "identify-eu-west-1.acrcloud.com"
        config.accessKey = "41eb0dc8541f8a793ebe5f402befc364"
        config.accessSecret = "h0igyw66jaOPgoPFskiGes1XUbzQbYQ3vpVzurgT"
        config.recMode = rec_mode_remote
        config.requestTimeout = 10
        config.protocol = "https"
        self.acrClient = ACRCloudRecognition(config: config)
    }
    
    // --- MODIFICATION 1 : La fusion renvoie aussi les plages valides ---
    /// Fusionne les audios et retourne l'URL + les intervalles où l'audio existe vraiment (en secondes relatives).
    // Dans class AnalysisManager :

        func mergeAudioFiles(urls: [URL]) async -> (URL?, [(start: Double, end: Double)]) {
            guard !urls.isEmpty else { return (nil, []) }
            
            // Cas fichier unique : on renvoie le fichier et une plage complète
            if urls.count == 1 {
                let asset = AVURLAsset(url: urls.first!)
                // Correction ambiguïté : on précise le type CMTime
                let duration: CMTime = (try? await asset.load(.duration)) ?? .zero
                return (urls.first, [(0, duration.seconds)])
            }
            
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return (nil, []) }
            
            // Correction optionnels : on utilise ?? 0 pour le tri
            let sortedURLs = urls.sorted { (extractTimestamp(from: $0) ?? 0) < (extractTimestamp(from: $1) ?? 0) }
            
            guard let firstFile = sortedURLs.first,
                  let startTimeBase = extractTimestamp(from: firstFile) else { return (nil, []) }
            
            var validRanges: [(start: Double, end: Double)] = []
            
            print("🧩 Fusion de \(sortedURLs.count) segments...")
            
            for url in sortedURLs {
                let asset = AVURLAsset(url: url)
                do {
                    // CORRECTION AMBIGUÏTÉ 1 : On dit explicitement à Swift qu'on attend un tableau de pistes
                    let tracks: [AVAssetTrack] = try await asset.load(.tracks)
                    guard let track = tracks.first else { continue }
                    
                    // CORRECTION AMBIGUÏTÉ 2 : On dit explicitement qu'on attend un CMTime
                    let duration: CMTime = try await asset.load(.duration)
                    
                    guard let fileTimestamp = extractTimestamp(from: url) else { continue }
                    
                    let timeOffset = fileTimestamp - startTimeBase
                    let insertTime = CMTime(seconds: timeOffset, preferredTimescale: 44100)
                    
                    try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: insertTime)
                    
                    // On enregistre la plage valide
                    validRanges.append((start: timeOffset, end: timeOffset + duration.seconds))
                    
                } catch {
                    print("⚠️ Erreur fusion segment: \(error)")
                }
            }
            
            let tempDir = FileManager.default.temporaryDirectory
            let outputURL = tempDir.appendingPathComponent("merged_session_\(Int(Date().timeIntervalSince1970)).m4a")
            try? FileManager.default.removeItem(at: outputURL)
            
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return (nil, []) }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            await exportSession.export()
            if exportSession.status == .completed {
                print("✅ Fusion terminée")
                // On renvoie l'URL ET les plages valides
                return (outputURL, validRanges)
            } else {
                return (nil, [])
            }
        }
    
    private func extractTimestamp(from url: URL) -> Double? {
        let filename = url.lastPathComponent.replacingOccurrences(of: ".wav", with: "")
        let components = filename.components(separatedBy: "_")
        if let last = components.last, let ts = Double(last) { return ts }
        return nil
    }
    
    // --- MODIFICATION 2 : On prend en compte les plages valides ---
    func analyzeSessionComplete(audioURL: URL, sensorsURL: URL, validAudioRanges: [(start: Double, end: Double)]) async -> [HighlightMoment] {
        guard let audioData = try? Data(contentsOf: audioURL) else { return [] }
        guard let csvString = try? String(contentsOf: sensorsURL, encoding: .utf8) else { return [] }
        
        let bytesPerSecond = 16000
        let totalDuration = Double(audioData.count) / Double(bytesPerSecond)
        let isShortSession = totalDuration < 600
        
        // On passe les plages valides à l'algo de détection
        let candidates = findSmartPeaks(csv: csvString, validAudioRanges: validAudioRanges)
        
        var recognizedMoments: [HighlightMoment] = []
        let total = Double(candidates.count)
        
        let asset = AVURLAsset(url: audioURL)
        
        for (index, candidate) in candidates.enumerated() {
            await MainActor.run { self.analysisProgress = Double(index) / total }
            
            let timestamp = candidate.t
            let score = candidate.score
            
            // Extraction audio (12s)
            if let chunk = await extractAudioChunk(asset: asset, at: timestamp, duration: 12) {
                let resultJSON = acrClient.recognize(chunk)
                if let song = parseResult(resultJSON) {
                    recognizedMoments.append(HighlightMoment(timestamp: timestamp, song: song, peakScore: score))
                } else {
                    // Même si pas reconnu, on garde le moment si le score est haut (optionnel)
                    // recognizedMoments.append(HighlightMoment(timestamp: timestamp, song: nil, peakScore: score))
                }
            }
        }
        
        await MainActor.run { self.analysisProgress = 1.0 }
        return filterMomentsSmartly(moments: recognizedMoments, isShortSession: isShortSession)
    }
    
    private func extractAudioChunk(asset: AVURLAsset, at time: TimeInterval, duration: Double) async -> Data? {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        
        let startTime = CMTime(seconds: max(0, time), preferredTimescale: 44100)
        let durationTime = CMTime(seconds: duration, preferredTimescale: 44100)
        let range = CMTimeRange(start: startTime, duration: durationTime)
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("chunk_\(UUID().uuidString).m4a")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = range
        
        await exportSession.export()
        
        if exportSession.status == .completed {
            let data = try? Data(contentsOf: outputURL)
            try? FileManager.default.removeItem(at: outputURL)
            return data
        }
        return nil
    }
    
    // --- MODIFICATION 3 : L'algo vérifie si l'audio existe ---
    private func findSmartPeaks(csv: String, validAudioRanges: [(start: Double, end: Double)]) -> [(t: Double, score: Double)] {
        let rows = csv.components(separatedBy: "\n").dropFirst()
        var data: [(t: Double, mag: Double)] = []
        for row in rows {
            let cols = row.components(separatedBy: ",")
            if cols.count >= 4, let t = Double(cols[0]), let x = Double(cols[1]), let y = Double(cols[2]), let z = Double(cols[3]) {
                let mag = sqrt(x*x + y*y + z*z)
                data.append((t, mag))
            }
        }
        guard !data.isEmpty else { return [] }
        let startTime = data[0].t
        let globalAverage = (data.map { $0.mag }.reduce(0, +) / Double(data.count)) + 0.001
        
        var windows: [(t: Double, score: Double)] = []
        let windowStep = 40 // ~4 sec
        
        if data.count > windowStep {
            for i in stride(from: 0, to: data.count - windowStep, by: windowStep) {
                let chunk = data[i..<i+windowStep]
                let chunkAvg = chunk.map { $0.mag }.reduce(0, +) / Double(chunk.count)
                let relativeScore = chunkAvg / globalAverage
                
                if let first = chunk.first {
                    let relativeTime = first.t - startTime
                    
                    // --- VÉRIFICATION CRUCIALE ---
                    // Est-ce que ce moment (relativeTime) tombe dans une zone où on a de l'audio ?
                    // On vérifie si le milieu de la fenêtre (relativeTime + 2s) est dans une plage valide.
                    let checkTime = relativeTime + 2.0
                    let hasAudio = validAudioRanges.contains { range in
                        return checkTime >= range.start && checkTime <= range.end
                    }
                    
                    if hasAudio {
                        windows.append((t: relativeTime, score: relativeScore))
                    }
                }
            }
        }
        
        let sortedWindows = windows.sorted { $0.score > $1.score }
        
        var selectedPeaks: [(t: Double, score: Double)] = []
        for window in sortedWindows {
            if selectedPeaks.count >= 10 { break }
            let isTooClose = selectedPeaks.contains { abs($0.t - window.t) < 120 }
            if !isTooClose { selectedPeaks.append(window) }
        }
        return selectedPeaks.sorted(by: { $0.t < $1.t })
    }
    
    private func filterMomentsSmartly(moments: [HighlightMoment], isShortSession: Bool) -> [HighlightMoment] {
        if isShortSession {
            if let best = moments.max(by: { $0.peakScore < $1.peakScore }) { return [best] }
            return []
        }
        var validMoments: [HighlightMoment] = []
        let rankedMoments = moments.sorted { $0.peakScore > $1.peakScore }
        for candidate in rankedMoments {
            let isDuplicate = validMoments.contains { valid in
                let sameSong = (valid.song?.title == candidate.song?.title)
                let timeDiff = abs(valid.timestamp - candidate.timestamp)
                return (sameSong && timeDiff < 300) || (!sameSong && timeDiff < 120)
            }
            if !isDuplicate { validMoments.append(candidate) }
            if validMoments.count >= 5 { break }
        }
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
