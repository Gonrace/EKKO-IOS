import SwiftUI
import CoreMotion
import AVFoundation
import ZIPFoundation
import Combine
import Foundation

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
// 📚 SECTION 2: GESTIONNAIRE D'HISTORIQUE (HistoryManager)
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
// 📱 SECTION 3: VUE PRINCIPALE (ContentView - Logique et Interface)
// ============================================================================
struct ContentView: View {
    
    // --- États de l'Application ---
    enum AppState { case idle, recording, analyzing, fastReport }
    @State private var currentState: AppState = .idle
    @State private var statusText: String = "Prêt à capturer la soirée."
    @State private var savedFiles: [URL] = []
    
    // --- Données et Chronomètre ---
    @State private var history: [PartyReport] = []
    @State private var highlightMoments: [HighlightMoment] = []
    @State private var elapsedTimeString: String = "00:00:00"
    
    @State private var timerSubscription: AnyCancellable?
    @State private var startTime: Date?
    @State private var showingStartAlert = false
    @State private var showingShortSessionAlert = false
    
    // --- Option Fast Report ON/OFF ---
    @State private var isFastReportEnabled: Bool = true
    
    // --- Managers (Injection de dépendances) ---
    @StateObject private var analysisManager = AnalysisManager()
    private let motionManager = MotionManager()
    private let audioRecorder = AudioRecorderManager()
    
    // 🔑 NOUVEAU: État pour suivre l'activité de l'application
    @State private var isAppActive: Bool = true

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    
                    // Header
                    Text("EKKO")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .padding(.top, 40)
                        .foregroundColor(.white)
                    
                    // Toggle Fast Report
                    HStack {
                        Image(systemName: isFastReportEnabled ? "bolt.fill" : "bolt.slash.fill").foregroundColor(isFastReportEnabled ? .yellow : .gray)
                        Text("Activer le Fast Report")
                        Spacer()
                        Toggle("", isOn: $isFastReportEnabled)
                            .labelsHidden()
                            .tint(.pink)
                    }
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    
                    // 🔑 CHANGEMENT: Statut dynamique et message d'interruption
                    Text(audioRecorder.wasInterrupted ?
                         "⚠️ REPRENDRE L'ENREGISTREMENT : Veuillez revenir sur l'application (premier plan) pour redémarrer l'enregistrement audio et le chronomètre." :
                         statusText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .foregroundColor(audioRecorder.wasInterrupted ? .red : .gray)
                    
                    // --- Contenu Principal Dynamique (Switch View) ---
                    switch currentState {
                        case .idle:
                            IdleView(
                                history: $history,
                                savedFiles: $savedFiles,
                                deleteHistoryAction: { indexSet in
                                    HistoryManager.shared.deleteReport(at: indexSet, from: &history)
                                },
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
                    
                    // --- Bouton d'Action Principal START / STOP ---
                    if currentState == .recording || currentState == .idle {
                        Button(action: {
                            if currentState == .idle {
                                showingStartAlert = true
                            } else {
                                // Logique d'arrêt
                                if let start = startTime, Date().timeIntervalSince(start) < 30 {
                                    showingShortSessionAlert = true
                                } else {
                                    // Déclenchement de l'arrêt et analyse
                                    Task {
                                        await stopAndAnalyze()
                                    }
                                }
                            }
                        }) {
                            Text(currentState == .recording ? "Terminer la Soirée" : "Démarrer la Capture")
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.white)
                                .background(
                                    currentState == .recording ?
                                    AnyView(Color.red) :
                                    AnyView(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.pink]), startPoint: .leading, endPoint: .trailing))
                                )
                                .cornerRadius(20)
                                .shadow(color: currentState == .recording ? Color.red.opacity(0.4) : Color.orange.opacity(0.4), radius: 10, x: 0, y: 5)
                        }
                        .padding(.horizontal, 40)
                        .padding(.bottom, 20)
                    }
                }
                .onAppear {
                    loadSavedFiles()
                    history = HistoryManager.shared.loadHistory()
                }
                .preferredColorScheme(.dark)
                
                // Alertes
                .alert("Avant de commencer", isPresented: $showingStartAlert) {
                    Button("C'est parti !", role: .cancel) { startSession() }
                } message: {
                    Text("Pour économiser la batterie, verrouillez l'écran et activez le Mode Avion.")
                }
                
                .alert("Déjà fini ?", isPresented: $showingShortSessionAlert) {
                    Button("Continuer", role: .cancel) {}
                    Button("Arrêter sans sauvegarder", role: .destructive) { cancelSession() }
                } message: {
                    Text("Moins de 30 secondes ? C'est trop court pour détecter une ambiance.")
                }
            }
            .navigationBarHidden(true)
        }
        // Détecte le retour de l'application au premier plan
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if !isAppActive {
                handleAppResumption()
            }
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppActive = false
        }
    }
    
    // MARK: - Méthodes de Gestion de Session
    
    func startSession() {
        currentState = .recording
        statusText = "🔴 Enregistrement en cours..."
        savedFiles.removeAll()
        
        // Démarrage technique des Managers
        audioRecorder.startRecording()
        motionManager.startUpdates(audioRecorder: self.audioRecorder)
        
        // Chronomètre
        startTime = Date()
        timerSubscription = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { _ in
            let diff = Date().timeIntervalSince(startTime ?? Date())
            let h = Int(diff) / 3600
            let m = Int(diff) / 60 % 60
            let s = Int(diff) % 60
            elapsedTimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }
    
    // Déclenche la reprise si l'application revient en premier plan et qu'elle a été interrompue
    func handleAppResumption() {
        if audioRecorder.wasInterrupted {
            print("🔊 Reprise forcée : L'application est revenue au premier plan.")
            // Tente la reprise via le manager (démarrage d'un nouveau segment)
            audioRecorder.resumeAfterForeground()
        }
    }
    
    /** Gère l'arrêt de l'enregistrement et le workflow d'analyse/sauvegarde (Fast Report ON/OFF) */
    func stopAndAnalyze() async {
        // Arrêt Chrono
        timerSubscription?.cancel()
        
        // 1. Arrêt matériel et récupération des chemins (SYNCHRONE)
        // audioRecorder.stopRecording() retourne maintenant [URL]
        let audioURLs = audioRecorder.stopRecording()
        guard let sensorsURL = motionManager.stopAndSaveToFile() else {
            statusText = "❌ Erreur de sauvegarde des fichiers."
            currentState = .idle
            return
        }
        
        // 2. Préparation ZIP et Metadata
        let metadataURL = motionManager.createMetadataFile(startTime: startTime ?? Date())

        // Utiliser compactMap pour ajouter metadataURL SEULEMENT si elle est non nulle
        var filesToZip = audioURLs
        filesToZip.append(sensorsURL)
        filesToZip.append(contentsOf: [metadataURL].compactMap { $0 })

        // Identification du fichier audio pour l'ANALYSE (on prend le premier)
        let analysisAudioURL = audioURLs.first

        if isFastReportEnabled {
            // --- PATH A : FAST REPORT ON (ANALYSE LOURDE) ---
            
            await MainActor.run {
                self.currentState = .analyzing
                // Avertissement que l'analyse ne porte que sur le premier segment
                self.statusText = audioURLs.count > 1 ? "Analyse (sur le premier segment audio)..." : "Analyse des mouvements et reconnaissance ACRCloud..."
            }
            
            // Pause vitale pour écriture disque
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            var moments: [HighlightMoment] = []
            // On n'analyse que le premier segment (compromis pour le pipeline actuel)
            if let urlToAnalyze = analysisAudioURL {
                moments = await analysisManager.analyzeSessionComplete(audioURL: urlToAnalyze, sensorsURL: sensorsURL)
            }
            
            // 4. Création du rapport et sauvegarde Historique
            let validMoments = moments.map {
                SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "")
            }
            // Utilisation du timestamp du dernier moment ou du temps écoulé total
            let finalDuration = Date().timeIntervalSince(startTime ?? Date())
            // 🔑 CORRECTION: Utilisation de validMoments
            let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
            HistoryManager.shared.saveReport(report)
            
            // 5. Mise à jour de l'interface vers le rapport (MainActor)
            await MainActor.run {
                self.highlightMoments = moments
                self.history = HistoryManager.shared.loadHistory()
                self.statusText = "Voici votre Top Kiff !"
                self.currentState = .fastReport
                
                // 6. ZIP et Nettoyage après l'analyse
                compressAndSave(files: filesToZip)
            }
            
        } else {
            // --- PATH B : FAST REPORT OFF (SAUVEGARDE SEULE) ---
            
            // 3. ZIP et Nettoyage immédiat
            compressAndSave(files: filesToZip)

            await MainActor.run {
                self.statusText = "Session sauvegardée dans les fichiers ZIP."
                self.currentState = .idle
                self.loadSavedFiles()
            }
        }
    }
    
    func cancelSession() {
        timerSubscription?.cancel()
        // Stop audioRecorder retourne l'array des segments enregistrés, mais on les ignore ici
        _ = audioRecorder.stopRecording()
        _ = motionManager.stopAndSaveToFile()
        currentState = .idle
        statusText = "Session annulée."
    }
    
    /** Calcule le numéro de la prochaine session en scannant les ZIP existants (Ex: EKKO005). */
    func getNewSessionNumber() -> Int {
        let fm = FileManager.default
        guard let doc = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 1 }
        
        // Recherche de tous les fichiers ZIP existants basés sur le préfixe "EKKO"
        let existingFiles = (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" && $0.lastPathComponent.starts(with: "EKKO") }) ?? []
        
        var maxNumber = 0
        let prefix = "EKKO"
        
        for url in existingFiles {
            let name = url.lastPathComponent
            // Tente d'extraire la chaîne numérique entre "EKKO" et le premier "_"
            if let startRange = name.range(of: prefix)?.upperBound,
               let endRange = name.range(of: "_", range: startRange..<name.endIndex)?.lowerBound {
                
                let numberString = String(name[startRange..<endRange])
                // Convertit la chaîne numérique (ex: "005") en Int
                if let number = Int(numberString) {
                    maxNumber = max(maxNumber, number)
                }
            }
        }
        return maxNumber + 1
    }
    
    /** Compresse les fichiers bruts en ZIP avec un nom lisible (EKKO001_YYYYMMDD_XHXXm.zip). */
    func compressAndSave(files: [URL]) {
        let fm = FileManager.default
        
        // Le premier fichier audio détermine la date de début de session.
        guard let firstAudioURL = files.first(where: { $0.pathExtension == "wav" }) else { return }
        
        // 1. EXTRAIRE LES TIMESTAMPS
        let originalFilename = firstAudioURL.lastPathComponent

        // Extraction du timestamp par plages
        let prefixToFind = "rec_seg_"
        
        guard let startOfTimestamp = originalFilename.range(of: prefixToFind)?.upperBound else {
            print("❌ Erreur: Préfixe audio non trouvé dans le nom du fichier.")
            return
        }

        // Extrait la sous-chaîne entre le préfixe et le ".wav"
        let timestampWithExt = originalFilename[startOfTimestamp...]
        guard let endOfTimestamp = timestampWithExt.range(of: ".wav")?.lowerBound else {
             print("❌ Erreur: Extension .wav non trouvée.")
             return
        }
        
        let timestampString = String(timestampWithExt[..<endOfTimestamp])
        
        guard let startTimeStamp = TimeInterval(timestampString) else {
            print("❌ Erreur: Impossible de convertir le timestamp en TimeInterval.")
            return
        }
        
        let endTimeStamp = Date().timeIntervalSince1970
        let durationSeconds = endTimeStamp - startTimeStamp // Durée totale, y compris les pauses
        
        // 2. CRÉER LE NUMÉRO DE SESSION
        let sessionNumber = getNewSessionNumber()
        // Format à trois chiffres (Ex: 1 -> 001)
        let sessionString = String(format: "%03d", sessionNumber)
        
        // 3. CALCULER LA DURÉE EN H/M (ex: 2h38m)
        let totalMinutes = Int(durationSeconds / 60.0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let durationString = String(format: "%dh%02dm", hours, minutes) // Format XhYYm
        
        // 4. CRÉER LA PARTIE DATE (Date de début de l'enregistrement)
        let startDate = Date(timeIntervalSince1970: startTimeStamp)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let datePart = dateFormatter.string(from: startDate)
        
        // 5. CONSTRUIRE LE NOM FINAL (Format: EKKO001_YYYYMMDD_XHXXm.zip)
        let newZipName = "EKKO\(sessionString)_\(datePart)_\(durationString).zip"
        // Utilisation du répertoire Caches
        guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let zipURL = cachePath.appendingPathComponent(newZipName)
        
        try? fm.removeItem(at: zipURL)
        
        do {
            let archive = try Archive(url: zipURL, accessMode: .create)
            for file in files {
                // Ajout des fichiers au ZIP
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
            }
            print("✅ ZIP créé : \(newZipName)")
            
            // Nettoyage des fichiers bruts après zippage
            for file in files {
                try fm.removeItem(at: file)
            }
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
        savedFiles = (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "zip" }
                        .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })) ?? []
    }
}

// ============================================================================
// 🎨 SECTION 4: SOUS-VUES (Interface SwiftUI)
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
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            if selectedTab == 0 {
                if history.isEmpty {
                    EmptyState(icon: "music.note.list", text: "Aucune soirée enregistrée.")
                } else {
                    List {
                        ForEach(history) { report in
                            NavigationLink(destination: HistoryDetailView(report: report)) {
                                VStack(alignment: .leading) {
                                    Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.headline).foregroundColor(.white)
                                    Text("\(report.moments.count) moment(s) fort(s)")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }
                        .onDelete(perform: deleteHistoryAction)
                    }
                    .scrollContentBackground(.hidden)
                }
            } else {
                if savedFiles.isEmpty {
                    EmptyState(icon: "doc.zipper", text: "Aucun fichier brut.")
                } else {
                    List {
                        ForEach(savedFiles, id: \.self) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    // Affiche le nouveau nom clair du fichier ZIP
                                    Text(file.lastPathComponent).font(.caption).foregroundColor(.white)
                                    Text(getFileSize(url: file)).font(.caption2).foregroundColor(.gray)
                                }
                                Spacer()
                                
                                // Bouton de partage
                                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                                    .padding(.leading, 10)
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

// Vues utilitaires et d'état
struct EmptyState: View {
    let icon: String
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Image(systemName: icon).font(.system(size: 50)).foregroundColor(.gray)
            Text(text).foregroundColor(.gray).padding(.top)
            Spacer()
        }
    }
}

struct RecordingView: View {
    @Binding var elapsedTimeString: String
    @State private var pulse = false
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            ZStack {
                Circle().stroke(Color.red.opacity(0.5), lineWidth: 2).frame(width: 200, height: 200)
                    .scaleEffect(pulse ? 1.2 : 1.0).opacity(pulse ? 0 : 1)
                    .onAppear { withAnimation(Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true } }
                
                Text(elapsedTimeString)
                    .font(.system(size: 50, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Text("Capture de l'ambiance...").foregroundColor(.gray)
            Spacer()
        }
    }
}

struct AnalyzingView: View {
    let progress: Double
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle(tint: Color.pink))
                .padding()
            Text("Analyse Intelligente en cours...").foregroundColor(.white)
            Text("\(Int(progress * 100))%").font(.caption).foregroundColor(.gray)
            Spacer()
        }
    }
}

struct FastReportView: View {
    @Binding var moments: [HighlightMoment]
    var onDone: () -> Void
    
    var body: some View {
        VStack {
            Text(moments.count == 1 ? "🏆 LE MOMENT D'OR" : "🔥 TOP 5 DE LA SOIRÉE")
                .font(.title2).bold().foregroundColor(.white).padding(.top)
            
            if moments.isEmpty {
                Spacer()
                Text("Aucune musique reconnue 😔").foregroundColor(.gray).padding()
                Spacer()
            } else {
                List {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in
                        HStack(spacing: 15) {
                            // Le Rang (1, 2, 3...)
                            ZStack {
                                Circle()
                                    .fill(index == 0 ? Color.yellow : (index == 1 ? Color.gray : Color.orange))
                                    .frame(width: 30, height: 30)
                                Text("\(index + 1)")
                                    .font(.headline)
                                    .foregroundColor(.black)
                            }
                            
                            VStack(alignment: .leading) {
                                Text(m.song?.title ?? "Inconnu")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(m.song?.artist ?? "")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            // L'heure du passage
                            Text(formatTime(m.timestamp))
                                .font(.system(.caption, design: .monospaced))
                                .padding(6)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                                .foregroundColor(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.1))
                        .padding(.vertical, 5)
                    }
                }
                .listStyle(.plain)
            }
            
            Button(action: { onDone() }) {
                Text("Sauvegarder et continuer")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(15)
            }
            .padding()
        }
        .background(Color.black)
    }
    
    func formatTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = Int(t) / 60 % 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else {
            return "\(m) min"
        }
    }
}

struct HistoryDetailView: View {
    let report: PartyReport
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            List(report.moments) { m in
                VStack(alignment: .leading) {
                    Text(m.title).font(.headline).foregroundColor(.white)
                    Text(m.artist).font(.caption).foregroundColor(.gray)
                    Text("À \(Int(m.timestamp / 60)) min \(Int(m.timestamp) % 60) s").font(.caption2).foregroundColor(.orange)
                }
                .listRowBackground(Color.white.opacity(0.1))
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Détails Soirée")
    }
}


// ============================================================================
// 🎤 SECTION 5: ENREGISTREUR AUDIO (AudioRecorderManager)
// Description: Gère l'enregistrement en segments et les interruptions.
// ============================================================================
class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {
    var audioRecorder: AVAudioRecorder?
    // 🔑 CHANGEMENT: Liste des URLs de tous les segments audio enregistrés
    var recordedFileUrls: [URL] = []
    var wasInterrupted = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // 🔑 NOUVELLE MÉTHODE : Configure et démarre un NOUVEL enregistreur
    private func setupAndStartNewRecorder() -> URL? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Erreur de configuration de la session audio: \(error)")
            return nil
        }

        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Utilisation d'un timestamp frais pour nommer le segment
        let filename = "rec_seg_\(Int(Date().timeIntervalSince1970)).wav"
        let newURL = docPath.appendingPathComponent(filename)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: newURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            self.recordedFileUrls.append(newURL) // Ajoute l'URL du nouveau segment
            print("✅ Nouvelle session d'enregistrement démarrée: \(filename)")
            return newURL
        } catch {
            print("❌ Erreur REC: \(error)");
            return nil
        }
    }

    // Gère l'interruption en arrêtant/démarrant un nouveau segment
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // Interruption Démarrée : Arrête le segment actuel pour le finaliser
            print("🔊 Interruption audio: Débutée. Arrêt du segment actuel.")
            self.wasInterrupted = true
            audioRecorder?.stop()
            
        case .ended:
            // 🔑 CHANGEMENT: Ne tente pas de reprendre ici, car on le gère au retour en premier plan.
            print("🔊 Interruption audio: Terminée détectée par le système, mais la reprise sera gérée au retour en premier plan.")
            // Laisse wasInterrupted à true pour que handleAppResumption prenne le relais.
            
        @unknown default:
            break
        }
    }
    
    // Démarre la première session
    func startRecording() {
        self.recordedFileUrls.removeAll()
        _ = setupAndStartNewRecorder()
    }
    
    // 🔑 NOUVELLE MÉTHODE : Permet à ContentView de forcer la reprise après une interruption.
    func resumeAfterForeground() {
        if self.wasInterrupted {
            print("🔊 Reprise forcée : Tente de démarrer un nouveau segment audio.")
            _ = setupAndStartNewRecorder()
            self.wasInterrupted = false
        }
    }
    
    // 🔑 CHANGEMENT: Retourne TOUTES les URLs des segments
    func stopRecording() -> [URL] {
        audioRecorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        
        let allUrls = self.recordedFileUrls
        self.recordedFileUrls.removeAll()
        
        return allUrls
    }
    
    // Reste inchangé
    func getCurrentPower() -> Float {
        audioRecorder?.updateMeters()
        return audioRecorder?.averagePower(forChannel: 0) ?? -160.0
    }
}

// ============================================================================
// 📊 SECTION 6: CAPTEURS & METADATA (MotionManager)
// ============================================================================

class MotionManager {
    private let mm = CMMotionManager()
    private var dataBuffer: [String] = []
    private var csvString = ""
    
    // Métadata de début
    private var batteryLevelStart: Float = 0.0
    private var batteryStateStart: String = ""
    private var startTime: Date = Date()
    private var fileURL: URL?

    func startUpdates(audioRecorder: AudioRecorderManager) {
        // En-tête CSV complet
        csvString = "timestamp,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,attitude_roll,attitude_pitch,attitude_yaw,gravity_x,gravity_y,gravity_z,audio_power_db\n"
        dataBuffer.removeAll()
        
        // Initialisation de la batterie/temps
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.batteryLevelStart = UIDevice.current.batteryLevel
        self.batteryStateStart = batteryStateString(UIDevice.current.batteryState)
        self.startTime = Date()

        // Le CSV utilise le dossier Documents
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = doc.appendingPathComponent("sensors_\(Int(Date().timeIntervalSince1970)).csv")

        mm.deviceMotionUpdateInterval = 0.1 // 10Hz
        mm.startDeviceMotionUpdates(to: .main) { (deviceMotion, error) in
            guard let data = deviceMotion else { return }
            
            let audioPower = audioRecorder.getCurrentPower()
            let timestamp = Date().timeIntervalSince1970

            // Capteurs complets
            let ax = data.userAcceleration.x; let ay = data.userAcceleration.y; let az = data.userAcceleration.z
            let gx = data.rotationRate.x; let gy = data.rotationRate.y; let gz = data.rotationRate.z
            let roll = data.attitude.roll; let pitch = data.attitude.pitch; let yaw = data.attitude.yaw
            let gravX = data.gravity.x; let gravY = data.gravity.y; let gravZ = data.gravity.z

            // Construction de la ligne CSV
            let newLine = "\(timestamp),\(ax),\(ay),\(az),\(gx),\(gy),\(gz),\(roll),\(pitch),\(yaw),\(gravX),\(gravY),\(gravZ),\(audioPower)\n"
            self.dataBuffer.append(newLine)
        }
    }
    
    private func writeBufferToString() {
        csvString.append(contentsOf: dataBuffer.joined())
        dataBuffer.removeAll()
    }
    
    func stopAndSaveToFile() -> URL? {
        mm.stopDeviceMotionUpdates()
        writeBufferToString()
        
        guard let url = fileURL else { return nil }
        do {
            try csvString.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("❌ Erreur sauvegarde CSV: \(error)")
            return nil
        }
    }
    
    // CRÉATION DU FICHIER METADATA
    func createMetadataFile(startTime: Date) -> URL? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevelEnd = UIDevice.current.batteryLevel
        let batteryStateEnd = batteryStateString(UIDevice.current.batteryState)
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        let metadataContent = """
        METADATA DE LA SESSION EKKO
        ------------------------------------------
        App Version: 1.0 (WAV Mode)
        
        --- DURÉE & HEURES ---
        Début: \(startTime)
        Fin: \(endTime)
        Durée Totale: \(String(format: "%.2f", duration / 60)) minutes
        
        --- APPAREIL & SYSTÈME ---
        Modèle Appareil: \(UIDevice.current.model)
        Version iOS: \(UIDevice.current.systemVersion)
        
        --- ENERGIE ---
        Batterie Début: \(String(format: "%.0f%%", self.batteryLevelStart * 100)) (\(self.batteryStateStart))
        Batterie Fin: \(String(format: "%.0f%%", batteryLevelEnd * 100)) (\(batteryStateEnd))
        Consommation Estimée: \(String(format: "%.1f%%", (self.batteryLevelStart - batteryLevelEnd) * 100))
        ------------------------------------------
        """
        
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let metadataURL = docPath.appendingPathComponent("metadata_\(Int(Date().timeIntervalSince1970)).txt")
        
        do {
            try metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8)
            return metadataURL
        } catch {
            print("❌ Erreur création metadata: \(error)")
            return nil
        }
    }
    
    private func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "Inconnu"
        case .unplugged: return "Débranché"
        case .charging: return "En charge"
        case .full: return "Pleine"
        @unknown default: return "Inconnu"
        }
    }
}

// ============================================================================
// 🧠 SECTION 7: ANALYSEUR INTELLIGENT (AnalysisManager)
// ============================================================================
class AnalysisManager: NSObject, ObservableObject {
    let acrClient: ACRCloudRecognition
    @Published var analysisProgress: Double = 0.0
    
    override init() {
        let config = ACRCloudConfig()
        config.host = "identify-eu-west-1.acrcloud.com"
        config.accessKey = "41eb0dc8541f8a793ebe5f402befc364"
        config.accessSecret = "h0igyw66jaOPgoPFskiGes1XUbzQbYQ3vpVzurgT"
        config.recMode = rec_mode_remote
        config.requestTimeout = 10
        config.protocol = "https"
        self.acrClient = ACRCloudRecognition(config: config)
    }
    
    /** Gère le flux d'analyse complet : lecture de fichiers, détection des pics, et reconnaissance ACRCloud. */
    func analyzeSessionComplete(audioURL: URL, sensorsURL: URL) async -> [HighlightMoment] {
        
        // 1. Lecture des fichiers
        guard let audioData = try? Data(contentsOf: audioURL) else {
            return []
        }
        guard let csvString = try? String(contentsOf: sensorsURL, encoding: .utf8) else {
            return []
        }
        
        let bytesPerSecond = 16000
        let totalDuration = Double(audioData.count) / Double(bytesPerSecond)
        let isShortSession = totalDuration < 600
        
        // 2. Détection des pics de mouvement
        let candidates = findSmartPeaks(csv: csvString, duration: totalDuration, minSpacing: 120)
        
        var recognizedMoments: [HighlightMoment] = []
        
        // 3. Boucle d'analyse ACRCloud
        let total = Double(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            await MainActor.run { self.analysisProgress = Double(index) / total }
            
            let timestamp = candidate.t
            let score = candidate.score
            
            let startByte = Int(timestamp) * bytesPerSecond
            let lengthByte = 12 * bytesPerSecond
            
            if startByte >= 0 && (startByte + lengthByte) < audioData.count {
                let chunk = audioData.subdata(in: startByte..<startByte+lengthByte)
                let resultJSON = acrClient.recognize(chunk)
                
                if let song = parseResult(resultJSON) {
                    recognizedMoments.append(HighlightMoment(timestamp: timestamp, song: song, peakScore: score))
                }
            }
        }
        
        await MainActor.run { self.analysisProgress = 1.0 }
        
        // 4. Filtrage (Règle Anti-Doublon et Top 5)
        return filterMomentsSmartly(moments: recognizedMoments, isShortSession: isShortSession)
    }
    
    /** Calcule les pics de mouvement relatifs et les filtre. Le type de retour est corrigé pour utiliser 'score'. */
    private func findSmartPeaks(csv: String, duration: Double, minSpacing: Double) -> [(t: Double, score: Double)] {
        
        let rows = csv.components(separatedBy: "\n").dropFirst()
        var data: [(t: Double, mag: Double)] = [] // 'mag' pour la magnitude brute
        
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
        
        var windows: [(t: Double, score: Double)] = [] // 'score' pour le score relatif
        let windowStep = 40 // ~4 secondes d'échantillons
        
        if data.count > windowStep {
            for i in stride(from: 0, to: data.count - windowStep, by: windowStep) {
                let chunk = data[i..<i+windowStep]
                let chunkAvg = chunk.map { $0.mag }.reduce(0, +) / Double(chunk.count)
                let relativeScore = chunkAvg / globalAverage
                if let first = chunk.first {
                    // Stockage sous le champ 'score' pour l'harmonisation
                    windows.append((t: first.t - startTime, score: relativeScore))
                }
            }
        }
        
        let sortedWindows = windows.sorted { $0.score > $1.score }
        
        var selectedPeaks: [(t: Double, score: Double)] = []
        
        for window in sortedWindows {
            if selectedPeaks.count >= 10 { break }
            
            // Le test utilise maintenant le champ '.t' (timestamp)
            let isTooClose = selectedPeaks.contains { abs($0.t - window.t) < minSpacing }
            if !isTooClose {
                selectedPeaks.append(window)
            }
        }
        
        return selectedPeaks.sorted(by: { $0.t < $1.t })
    }
    
    /** Implémente la Règle Anti-Doublon et sélectionne le Top 5 final. */
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
                let closeTime = timeDiff < 300 // 5 minutes
                
                if sameSong && closeTime { return true }
                if !sameSong && timeDiff < 120 { return true }
                return false
            }
            
            if !isDuplicate {
                validMoments.append(candidate)
            }
            
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
