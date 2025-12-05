import SwiftUI
import CoreMotion
import AVFoundation
import ZIPFoundation // Assurez-vous d'avoir ajouté le package ZIPFoundation
import Combine
import Foundation

// ============================================================================
// 🎯 SECTION 1: MODÈLES DE DONNÉES
// Description : Ces structures définissent le format des données manipulées par l'app.
// ============================================================================

/// Représente un moment fort détecté pendant l'analyse (non sauvegardé sur disque, utilisé en RAM).
struct HighlightMoment: Identifiable, Hashable {
    let id = UUID()
    let timestamp: TimeInterval // Moment précis en secondes depuis le début
    var song: RecognizedSong? = nil // Musique reconnue (optionnel)
    let peakScore: Double       // Intensité du mouvement à ce moment
}

/// Structure simple pour une chanson reconnue.
struct RecognizedSong: Hashable {
    let title: String
    let artist: String
}

/// Structure finale du rapport sauvegardé dans l'historique (JSON).
struct PartyReport: Identifiable, Codable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
    let moments: [SavedMoment]
}

/// Version allégée d'un moment pour la sauvegarde JSON.
struct SavedMoment: Codable, Identifiable {
    var id = UUID()
    let timestamp: TimeInterval
    let title: String
    let artist: String
}

// ============================================================================
// 📚 SECTION 2: GESTIONNAIRE D'HISTORIQUE & TAGS
// Description : Gère la persistance des rapports (JSON) et des tags (UserDefaults/ZIP).
// ============================================================================

class HistoryManager {
    static let shared = HistoryManager()
    private let fileName = "party_history.json"
    private let tagsKey = "EKKO_FileTags" // Clé pour le cache local des tags dans UserDefaults
    
    // --- GESTION DU FICHIER JSON ---
    
    /// Retourne l'URL du fichier JSON contenant l'historique des soirées.
    func getHistoryFileURL() -> URL? {
        guard let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docPath.appendingPathComponent(fileName)
    }
    
    /// Sauvegarde un nouveau rapport en tête de liste.
    func saveReport(_ report: PartyReport) {
        var history = loadHistory()
        history.insert(report, at: 0)
        guard let url = getHistoryFileURL(), let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url)
    }
    
    /// Charge la liste complète des rapports depuis le disque.
    func loadHistory() -> [PartyReport] {
        guard let url = getHistoryFileURL(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PartyReport].self, from: data)) ?? []
    }
    
    /// Supprime un rapport spécifique.
    func deleteReport(at offsets: IndexSet, from history: inout [PartyReport]) {
        history.remove(atOffsets: offsets)
        guard let url = getHistoryFileURL(), let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url)
    }
    
    // --- GESTION DES TAGS (CACHE LOCAL) ---
    // Note : Ces fonctions gèrent l'affichage rapide des tags dans l'interface.
    // Le stockage "réel" et portable se fait dans le fichier ZIP via ContentView.
    
    func saveTagLocalCache(_ tag: String, for filename: String) {
        var tags = loadTags()
        tags[filename] = tag
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: tagsKey)
        }
    }
    
    func getTag(for filename: String) -> String? {
        let tags = loadTags()
        return tags[filename]
    }
    
    func loadTags() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: tagsKey),
              let tags = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return tags
    }
}

// ============================================================================
// 📱 SECTION 3: VUE PRINCIPALE (ContentView)
// Description : Le coeur de l'application. Gère l'interface, les états, et l'orchestration.
// ============================================================================

struct ContentView: View {
    
    // --- Propriétés Globales ---
    
    /// Récupère dynamiquement la version (ex: 2.0) et le build (ex: 12) depuis Xcode.
    static var appVersionInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Inconnu"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Inconnu"
        return "Version \(version) (Build \(build))"
    }
    
    // --- États de l'Application (State) ---
    enum AppState { case idle, recording, analyzing, fastReport }
    @State private var currentState: AppState = .idle
    @State private var statusText: String = "Prêt à capturer la soirée."
    @State private var savedFiles: [URL] = [] // Liste des fichiers ZIP
    
    // --- Données & Chrono ---
    @State private var history: [PartyReport] = []
    @State private var highlightMoments: [HighlightMoment] = []
    @State private var elapsedTimeString: String = "00:00:00"
    @State private var timerSubscription: AnyCancellable?
    @State private var startTime: Date?
    
    // --- Alertes & Options ---
    @State private var showingStartAlert = false
    @State private var showingShortSessionAlert = false
    @State private var isFastReportEnabled: Bool = true
    
    // --- Gestion des Tags (Interface) ---
    @State private var showingTagAlert = false
    @State private var fileToTag: URL?
    @State private var tagInput: String = ""
    @State private var fileTags: [String: String] = [:] // Cache local pour affichage UI
    
    // --- Managers (Injection de dépendances) ---
    @StateObject private var analysisManager = AnalysisManager()
    private let motionManager = MotionManager()
    private let audioRecorder = AudioRecorderManager() // Gère l'audio segmenté
    
    // --- État Système ---
    @State private var isAppActive: Bool = true // Pour savoir si l'app est au premier plan
    
    // ========================================================================
    // MARK: - INTERFACE UTILISATEUR (BODY)
    // ========================================================================
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    
                    // 1. Titre
                    Text("EKKO")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .padding(.top, 40)
                        .foregroundColor(.white)
                    
                    // 2. Toggle Fast Report
                    HStack {
                        Image(systemName: isFastReportEnabled ? "bolt.fill" : "bolt.slash.fill")
                            .foregroundColor(isFastReportEnabled ? .yellow : .gray)
                        Text("Activer le Fast Report")
                        Spacer()
                        Toggle("", isOn: $isFastReportEnabled).labelsHidden().tint(.pink)
                    }
                    .padding().background(Color.white.opacity(0.1)).cornerRadius(10).padding(.horizontal)
                    
                    // 3. Zone de Statut (Gestion Interruption)
                    // Affiche un message rouge si l'audio a été coupé par un appel
                    Text(audioRecorder.wasInterrupted ?
                         "⚠️ REPRENDRE L'ENREGISTREMENT : L'audio a été coupé par le système. Revenez sur l'application (premier plan) pour relancer un segment." :
                         statusText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .foregroundColor(audioRecorder.wasInterrupted ? .red : .gray)
                    
                    // 4. Switcher de Vues Principal
                    switch currentState {
                        case .idle:
                            // Vue d'accueil (Liste des fichiers et historique)
                            IdleView(
                                history: $history,
                                savedFiles: $savedFiles,
                                fileTags: $fileTags,
                                deleteHistoryAction: { indexSet in HistoryManager.shared.deleteReport(at: indexSet, from: &history) },
                                deleteFileAction: deleteFiles,
                                onTagAction: { url in
                                    // Prépare l'alerte pour taguer un fichier
                                    fileToTag = url
                                    tagInput = HistoryManager.shared.getTag(for: url.lastPathComponent) ?? ""
                                    showingTagAlert = true
                                }
                            )
                        case .recording:
                            // Vue pendant l'enregistrement (Chrono)
                            RecordingView(elapsedTimeString: $elapsedTimeString)
                        case .analyzing:
                            // Vue de chargement
                            AnalyzingView(progress: analysisManager.analysisProgress)
                        case .fastReport:
                            // Vue de résultat immédiat
                            FastReportView(moments: $highlightMoments, onDone: {
                                currentState = .idle
                                statusText = "Prêt pour une nouvelle soirée."
                                loadSavedFiles()
                                history = HistoryManager.shared.loadHistory()
                            })
                    }
                    
                    // 5. Version en bas de page
                    Text(ContentView.appVersionInfo)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.top, 5)
                    
                    // 6. Gros Bouton d'Action (Start / Stop)
                    if currentState == .recording || currentState == .idle {
                        Button(action: {
                            if currentState == .idle {
                                showingStartAlert = true
                            } else {
                                // Vérification session courte
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
                    // Chargement initial des données
                    loadSavedFiles()
                    history = HistoryManager.shared.loadHistory()
                    fileTags = HistoryManager.shared.loadTags()
                }
                .preferredColorScheme(.dark)
                
                // --- LES ALERTES (Pop-ups) ---
                
                // Alerte pour ajouter un Tag
                .alert("Ajouter un Tag", isPresented: $showingTagAlert) {
                    TextField("Ex: Anniv Thomas", text: $tagInput)
                    Button("Annuler", role: .cancel) {
                        fileToTag = nil; tagInput = ""
                    }
                    Button("Sauvegarder") {
                        if let url = fileToTag {
                            // C'est ici que la magie opère : modification du ZIP
                            addTagFileToZip(zipURL: url, tag: tagInput)
                            fileTags = HistoryManager.shared.loadTags() // Rafraîchir UI
                        }
                    }
                } message: {
                    Text("Ajoutez un mot-clé. Il sera intégré directement dans le fichier ZIP (tag.txt).")
                }
                
                // Alerte Avant démarrage
                .alert("Avant de commencer", isPresented: $showingStartAlert) {
                    Button("C'est parti !", role: .cancel) { startSession() }
                } message: { Text("Verrouillez l'écran et activez le Mode Avion pour la batterie.") }
                
                // Alerte Session trop courte
                .alert("Déjà fini ?", isPresented: $showingShortSessionAlert) {
                    Button("Continuer", role: .cancel) {}
                    Button("Arrêter sans sauvegarder", role: .destructive) { cancelSession() }
                } message: { Text("Moins de 30 secondes ? C'est trop court.") }
            }
            .navigationBarHidden(true)
        }
        // --- OBSERVATEURS SYSTÈME (Gestion Background/Foreground) ---
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if !isAppActive { handleAppResumption() } // L'app revient : on tente de reprendre l'enregistrement
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppActive = false
        }
    }
    
    // ========================================================================
    // MARK: - LOGIQUE MÉTIER
    // ========================================================================
    
    /// Démarre une nouvelle session d'enregistrement.
    func startSession() {
        currentState = .recording
        statusText = "🔴 Enregistrement en cours..."
        savedFiles.removeAll()
        
        // Lance les managers
        audioRecorder.startRecording()
        motionManager.startUpdates(audioRecorder: self.audioRecorder)
        
        // Lance le chrono UI
        startTime = Date()
        timerSubscription = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { _ in
            let diff = Date().timeIntervalSince(startTime ?? Date())
            let h = Int(diff) / 3600
            let m = Int(diff) / 60 % 60
            let s = Int(diff) % 60
            elapsedTimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }
    
    /// Gère la reprise de l'enregistrement quand l'utilisateur revient sur l'app.
    /// C'est crucial car iOS coupe le micro lors d'un appel. Cette fonction relance un nouveau segment.
    func handleAppResumption() {
        if audioRecorder.wasInterrupted {
            print("🔊 Reprise forcée : L'application est revenue au premier plan.")
            audioRecorder.resumeAfterForeground()
        }
    }
    
    /// Arrête l'enregistrement, sauvegarde les fichiers et lance l'analyse (ou juste le zip).
    func stopAndAnalyze() async {
        timerSubscription?.cancel()
        
        // 1. Récupérer TOUS les segments audio (il peut y en avoir plusieurs si interruption)
        let audioURLs = audioRecorder.stopRecording()
        
        // 2. Sauvegarder le CSV des capteurs
        guard let sensorsURL = motionManager.stopAndSaveToFile() else {
            statusText = "❌ Erreur de sauvegarde."
            currentState = .idle
            return
        }
        
        // 3. Créer le fichier Metadata
        let metadataURL = motionManager.createMetadataFile(startTime: startTime ?? Date())
        
        // 4. Préparer la liste des fichiers pour le ZIP
        var filesToZip = audioURLs
        filesToZip.append(sensorsURL)
        filesToZip.append(contentsOf: [metadataURL].compactMap { $0 })
        
        // Pour l'analyse rapide, on prend seulement le PREMIER segment audio (Compromis V2)
        let analysisAudioURL = audioURLs.first
        
        if isFastReportEnabled {
            // --- MODE FAST REPORT ---
            await MainActor.run {
                self.currentState = .analyzing
                self.statusText = audioURLs.count > 1 ? "Analyse (segment 1)..." : "Analyse..."
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            var moments: [HighlightMoment] = []
            if let urlToAnalyze = analysisAudioURL {
                moments = await analysisManager.analyzeSessionComplete(audioURL: urlToAnalyze, sensorsURL: sensorsURL)
            }
            
            // Création et sauvegarde du rapport
            let validMoments = moments.map { SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "") }
            let finalDuration = Date().timeIntervalSince(startTime ?? Date())
            let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
            HistoryManager.shared.saveReport(report)
            
            await MainActor.run {
                self.highlightMoments = moments
                self.history = HistoryManager.shared.loadHistory()
                self.statusText = "Voici votre Top Kiff !"
                self.currentState = .fastReport
                // Création du ZIP final
                compressAndSave(files: filesToZip)
            }
        } else {
            // --- MODE SAUVEGARDE SEULE ---
            compressAndSave(files: filesToZip)
            await MainActor.run {
                self.statusText = "Sauvegardé."
                self.currentState = .idle
                self.loadSavedFiles()
            }
        }
    }
    
    /// Annule tout sans sauvegarder.
    func cancelSession() {
        timerSubscription?.cancel()
        _ = audioRecorder.stopRecording()
        _ = motionManager.stopAndSaveToFile()
        currentState = .idle
        statusText = "Session annulée."
    }
    
    /// Fonction clé pour la portabilité des tags.
    /// Modifie le fichier ZIP existant pour y injecter un fichier 'tag.txt'.
    func addTagFileToZip(zipURL: URL, tag: String) {
        let fm = FileManager.default
        let tagContent = tag
        
        // Fichier temporaire
        let tempTagURL = fm.temporaryDirectory.appendingPathComponent("tag_\(UUID().uuidString).txt")
        
        do {
            try tagContent.write(to: tempTagURL, atomically: true, encoding: .utf8)
            
            // Ouverture du ZIP en mode UPDATE
            let archive = try Archive(url: zipURL, accessMode: .update)
            // Ajout du fichier tag.txt
            try archive.addEntry(with: "tag.txt", relativeTo: tempTagURL, compressionMethod: .none)
            
            try fm.removeItem(at: tempTagURL)
            print("✅ Tag '\(tag)' intégré dans le ZIP : \(zipURL.lastPathComponent)")
            
            // Mise à jour du cache local pour l'affichage immédiat
            HistoryManager.shared.saveTagLocalCache(tag, for: zipURL.lastPathComponent)
            
        } catch {
            print("❌ Erreur lors de l'ajout du tag au ZIP: \(error)")
            try? fm.removeItem(at: tempTagURL)
        }
    }
    
    /// Compresse les fichiers bruts en un fichier ZIP final.
    /// Format : EKKO[HEURE]_[DATE]_[DUREE].zip (ex: EKKO2010_20251205_2h30m.zip)
    func compressAndSave(files: [URL]) {
        let fm = FileManager.default
        
        // On détermine la date de début grâce au nom du premier fichier audio (rec_seg_TIMESTAMP.wav)
        guard let firstAudioURL = files.first(where: { $0.pathExtension == "wav" }) else { return }
        let originalFilename = firstAudioURL.lastPathComponent
        let prefixToFind = "rec_seg_"
        
        // Extraction du timestamp (Logique string sécurisée)
        guard let startOfTimestamp = originalFilename.range(of: prefixToFind)?.upperBound else { return }
        let timestampWithExt = originalFilename[startOfTimestamp...]
        guard let endOfTimestamp = timestampWithExt.range(of: ".wav")?.lowerBound else { return }
        let timestampString = String(timestampWithExt[..<endOfTimestamp])
        guard let startTimeStamp = TimeInterval(timestampString) else { return }
        
        let startDate = Date(timeIntervalSince1970: startTimeStamp)
        let endTimeStamp = Date().timeIntervalSince1970
        let durationSeconds = endTimeStamp - startTimeStamp
        
        // Formatage du nom
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "HHmm"
        let timePart = timeFormatter.string(from: startDate)
        
        let totalMinutes = Int(durationSeconds / 60.0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let durationString = String(format: "%dh%02dm", hours, minutes)
        
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyyMMdd"
        let datePart = dateFormatter.string(from: startDate)
        
        let newZipName = "EKKO\(timePart)_\(datePart)_\(durationString).zip"
        
        // Stockage dans CACHES (pour éviter les erreurs iCloud/Partage système)
        guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let zipURL = cachePath.appendingPathComponent(newZipName)
        
        try? fm.removeItem(at: zipURL)
        
        do {
            let archive = try Archive(url: zipURL, accessMode: .create)
            for file in files {
                // Ajout au ZIP
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
            }
            print("✅ ZIP créé : \(newZipName)")
            // Nettoyage des fichiers bruts originaux
            for file in files { try fm.removeItem(at: file) }
        } catch {
            print("❌ Erreur Zip: \(error)")
        }
        loadSavedFiles()
    }
    
    /// Supprime les fichiers ZIP sélectionnés et leur tag associé.
    func deleteFiles(at offsets: IndexSet) {
        let fm = FileManager.default
        offsets.map { savedFiles[$0] }.forEach { try? fm.removeItem(at: $0) }
        loadSavedFiles()
        fileTags = HistoryManager.shared.loadTags() // Rafraîchir
    }
    
    /// Charge la liste des fichiers ZIP disponibles.
    func loadSavedFiles() {
        let fm = FileManager.default
        guard let doc = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        savedFiles = (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)
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
    @Binding var fileTags: [String: String]
    var deleteHistoryAction: (IndexSet) -> Void
    var deleteFileAction: (IndexSet) -> Void
    var onTagAction: (URL) -> Void
    
    @State private var selectedTab = 0
    
    var body: some View {
        VStack {
            Picker("Affichage", selection: $selectedTab) {
                Text("Journal").tag(0)
                Text("Fichiers ZIP").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle()).padding()
            
            if selectedTab == 0 {
                // VUE JOURNAL
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
                // VUE FICHIERS ZIP
                if savedFiles.isEmpty { EmptyState(icon: "doc.zipper", text: "Aucun fichier brut.") }
                else {
                    List {
                        ForEach(savedFiles, id: \.self) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(file.lastPathComponent).font(.caption).foregroundColor(.white)
                                    Text(getFileSize(url: file)).font(.caption2).foregroundColor(.gray)
                                    // Affichage du Tag si présent
                                    if let tag = fileTags[file.lastPathComponent], !tag.isEmpty {
                                        Text("🏷 \(tag)")
                                            .font(.caption2)
                                            .padding(4)
                                            .background(Color.blue.opacity(0.6))
                                            .cornerRadius(4)
                                            .foregroundColor(.white)
                                    }
                                }
                                Spacer()
                                
                                // Bouton pour Ajouter/Modifier le Tag
                                Button(action: { onTagAction(file) }) {
                                    Image(systemName: "tag.fill").foregroundColor(.yellow)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .padding(.trailing, 10)
                                
                                // Bouton Partage iOS natif
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

// Vue pour état vide
struct EmptyState: View {
    let icon: String; let text: String
    var body: some View { VStack { Spacer(); Image(systemName: icon).font(.system(size: 50)).foregroundColor(.gray); Text(text).foregroundColor(.gray).padding(.top); Spacer() } }
}

// Vue pendant l'enregistrement
struct RecordingView: View {
    @Binding var elapsedTimeString: String; @State private var pulse = false
    var body: some View { VStack(spacing: 30) { Spacer(); ZStack { Circle().stroke(Color.red.opacity(0.5), lineWidth: 2).frame(width: 200, height: 200).scaleEffect(pulse ? 1.2 : 1.0).opacity(pulse ? 0 : 1).onAppear { withAnimation(Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true } }; Text(elapsedTimeString).font(.system(size: 50, weight: .bold, design: .monospaced)).foregroundColor(.white) }; Text("Capture de l'ambiance...").foregroundColor(.gray); Spacer() } }
}

// Vue de chargement
struct AnalyzingView: View {
    let progress: Double
    var body: some View { VStack(spacing: 20) { Spacer(); ProgressView(value: progress).progressViewStyle(LinearProgressViewStyle(tint: Color.pink)).padding(); Text("Analyse Intelligente en cours...").foregroundColor(.white); Text("\(Int(progress * 100))%").font(.caption).foregroundColor(.gray); Spacer() } }
}

// Vue de résultat
struct FastReportView: View {
    @Binding var moments: [HighlightMoment]; var onDone: () -> Void
    var body: some View { VStack { Text(moments.count == 1 ? "🏆 LE MOMENT D'OR" : "🔥 TOP 5 DE LA SOIRÉE").font(.title2).bold().foregroundColor(.white).padding(.top); if moments.isEmpty { Spacer(); Text("Aucune musique reconnue 😔").foregroundColor(.gray).padding(); Spacer() } else { List { ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in HStack(spacing: 15) { ZStack { Circle().fill(index == 0 ? Color.yellow : (index == 1 ? Color.gray : Color.orange)).frame(width: 30, height: 30); Text("\(index + 1)").font(.headline).foregroundColor(.black) }; VStack(alignment: .leading) { Text(m.song?.title ?? "Inconnu").font(.headline).foregroundColor(.white); Text(m.song?.artist ?? "").font(.caption).foregroundColor(.gray) }; Spacer(); Text(formatTime(m.timestamp)).font(.system(.caption, design: .monospaced)).padding(6).background(Color.white.opacity(0.1)).cornerRadius(8).foregroundColor(.white) }.listRowBackground(Color.white.opacity(0.1)).padding(.vertical, 5) } }.listStyle(.plain) }; Button(action: { onDone() }) { Text("Sauvegarder et continuer").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.blue).cornerRadius(15) }.padding() }.background(Color.black) }
    func formatTime(_ t: TimeInterval) -> String { let h = Int(t) / 3600; let m = Int(t) / 60 % 60; if h > 0 { return "\(h)h \(m)m" } else { return "\(m) min" } }
}

// Vue de détail historique
struct HistoryDetailView: View {
    let report: PartyReport
    var body: some View { ZStack { Color.black.ignoresSafeArea(); List(report.moments) { m in VStack(alignment: .leading) { Text(m.title).font(.headline).foregroundColor(.white); Text(m.artist).font(.caption).foregroundColor(.gray); Text("À \(Int(m.timestamp / 60)) min \(Int(m.timestamp) % 60) s").font(.caption2).foregroundColor(.orange) }.listRowBackground(Color.white.opacity(0.1)) }.scrollContentBackground(.hidden) }.navigationTitle("Détails Soirée") }
}

// ============================================================================
// 🎤 SECTION 5: MANAGER AUDIO (AudioRecorderManager)
// Description : Gère l'enregistrement WAV. Spécialité : Découpe en segments si interrompu.
// ============================================================================

class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {
    var audioRecorder: AVAudioRecorder?
    var recordedFileUrls: [URL] = [] // Liste de tous les morceaux (segments) de la soirée
    var wasInterrupted = false // Drapeau : Vrai si l'audio a été coupé brutalement (appel)

    override init() {
        super.init()
        // Écoute les notifications système d'interruption (Appel, Siri, Alarme...)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    
    /// Initialise et lance l'enregistrement dans un NOUVEAU fichier segment.
    private func setupAndStartNewRecorder() -> URL? {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        try? session.setActive(true)
        
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Nom du fichier basé sur le timestamp actuel (pour le tri et la fusion future)
        let filename = "rec_seg_\(Int(Date().timeIntervalSince1970)).wav"
        let newURL = docPath.appendingPathComponent(filename)
        
        // Qualité standard (PCM 16-bit, 8kHz pour la voix/ambiance)
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false]
        
        do {
            audioRecorder = try AVAudioRecorder(url: newURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            self.recordedFileUrls.append(newURL) // On garde la trace de ce segment
            print("✅ Nouvelle session audio: \(filename)")
            return newURL
        } catch {
            print("❌ Erreur REC: \(error)")
            return nil
        }
    }

    /// Appelé par iOS quand une interruption survient (ex: Appel entrant).
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo, let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            // L'interruption commence : On arrête proprement le fichier en cours pour le sauvegarder.
            print("🔊 Interruption audio (Début). Arrêt du segment.")
            self.wasInterrupted = true
            audioRecorder?.stop()
        case .ended:
            // L'interruption est finie (ex: Appel terminé).
            // NOTE : On ne relance PAS l'enregistrement ici car l'app est souvent encore en background.
            // On attend que l'utilisateur revienne sur l'app (handleAppResumption dans ContentView).
            print("🔊 Fin interruption système.")
        @unknown default: break
        }
    }
    
    /// Démarre le tout premier enregistrement.
    func startRecording() {
        self.recordedFileUrls.removeAll()
        _ = setupAndStartNewRecorder()
    }
    
    /// Méthode appelée par ContentView quand l'app revient au premier plan après une coupure.
    func resumeAfterForeground() {
        if self.wasInterrupted {
            // On lance un nouveau segment pour continuer la soirée
            _ = setupAndStartNewRecorder()
            self.wasInterrupted = false
        }
    }
    
    /// Arrête tout et retourne la liste de tous les fichiers audios créés.
    func stopRecording() -> [URL] {
        audioRecorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        let all = self.recordedFileUrls
        self.recordedFileUrls.removeAll()
        return all
    }
    
    /// Pour l'animation visuelle (ondes).
    func getCurrentPower() -> Float {
        audioRecorder?.updateMeters()
        return audioRecorder?.averagePower(forChannel: 0) ?? -160.0
    }
}

// ============================================================================
// 📊 SECTION 6: MANAGER CAPTEURS (MotionManager)
// Description : Enregistre Accéléromètre, Gyroscope et Niveau sonore dans un CSV.
// ============================================================================

class MotionManager {
    private let mm = CMMotionManager()
    private var dataBuffer: [String] = [] // Tampon pour éviter d'écrire disque trop souvent
    private var csvString = ""
    private var batteryLevelStart: Float = 0.0
    private var startTime: Date = Date()
    private var fileURL: URL?

    func startUpdates(audioRecorder: AudioRecorderManager) {
        // En-tête du CSV
        csvString = "timestamp,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,attitude_roll,attitude_pitch,attitude_yaw,gravity_x,gravity_y,gravity_z,audio_power_db\n"
        dataBuffer.removeAll()
        
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.batteryLevelStart = UIDevice.current.batteryLevel
        self.startTime = Date()
        
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = doc.appendingPathComponent("sensors_\(Int(Date().timeIntervalSince1970)).csv")
        
        mm.deviceMotionUpdateInterval = 0.1 // Fréquence : 10Hz (10 points par seconde)
        mm.startDeviceMotionUpdates(to: .main) { (deviceMotion, error) in
            guard let data = deviceMotion else { return }
            
            let audioPower = audioRecorder.getCurrentPower()
            let timestamp = Date().timeIntervalSince1970
            
            // Formatage de la ligne CSV
            let newLine = "\(timestamp),\(data.userAcceleration.x),\(data.userAcceleration.y),\(data.userAcceleration.z),\(data.rotationRate.x),\(data.rotationRate.y),\(data.rotationRate.z),\(data.attitude.roll),\(data.attitude.pitch),\(data.attitude.yaw),\(data.gravity.x),\(data.gravity.y),\(data.gravity.z),\(audioPower)\n"
            self.dataBuffer.append(newLine)
        }
    }
    
    func stopAndSaveToFile() -> URL? {
        mm.stopDeviceMotionUpdates()
        // Écriture finale
        csvString.append(contentsOf: dataBuffer.joined())
        dataBuffer.removeAll()
        
        guard let url = fileURL else { return nil }
        try? csvString.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    /// Génère le fichier texte de métadonnées (Info téléphone, batterie, version).
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
// 🧠 SECTION 7: MANAGER ANALYSE (AnalysisManager)
// Description : Gère l'envoi des données à ACRCloud pour reconnaissance musicale.
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
            let isTooClose = selectedPeaks.contains { abs($0.t - window.t) < 120 } // 120s minSpacing
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
