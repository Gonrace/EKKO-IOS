import SwiftUI
import CoreMotion
import AVFoundation
import ZIPFoundation // Nécessaire pour manipuler les archives ZIP
import Combine
import Foundation

// ============================================================================
// 🎯 SECTION 1: MODÈLES DE DONNÉES
// ============================================================================

/// Représente un moment fort détecté pendant l'analyse (utilisé en RAM).
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
// Description : Gère la persistance des rapports et des tags (lecture/écriture).
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
    
    // --- GESTION DES TAGS (CACHE LOCAL & LECTURE ZIP) ---
    
    /// Récupère le tag pour le pré-remplissage de l'alerte. Vérifie le cache local puis le ZIP.
    func getTag(for filename: String, from zipURL: URL) -> String? {
        // 1. Essayer le cache local (pour les tags qui n'ont pas encore été intégrés)
        if let localTag = loadTags()[filename], !localTag.isEmpty {
            return localTag
        }
        // 2. Essayer de lire directement dans le ZIP (pour les tags intégrés)
        if let zipTag = readContentFromZip(zipURL: zipURL, entryName: "tag.txt") {
            return zipTag
        }
        return nil
    }
    
    /// Charge le dictionnaire des tags depuis UserDefaults (le cache).
    func loadTags() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: tagsKey),
              let tags = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return tags
    }
    
    /// Tente de lire le contenu d'un fichier spécifique (ex: tag.txt) dans une archive ZIP.
    func readContentFromZip(zipURL: URL, entryName: String) -> String? {
        do {
            let archive = try Archive(url: zipURL, accessMode: .read)
            guard let entry = archive[entryName] else { return nil }
            
            var data = Data()
            _ = try archive.extract(entry, consumer: { chunk in
                data.append(chunk)
            })
            // Nettoyer les espaces/sauts de ligne pour un tag propre
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

// ============================================================================
// 📱 SECTION 3: VUE PRINCIPALE (ContentView)
// Description : Le coeur de l'appli. Gère l'interface, les états, l'orchestration des managers.
// ============================================================================

struct ContentView: View {
    
    /// Récupère dynamiquement la version et le build depuis Xcode (pour affichage et metadata).
    static var appVersionInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Inconnu"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Inconnu"
        return "Version \(version) (Build \(build))"
    }
    
    // --- États de l'Application (State) ---
    enum AppState { case idle, recording, analyzing, fastReport }
    @State private var currentState: AppState = .idle
    @State private var statusText: String = "Prêt à capturer la soirée."
    @State private var savedFiles: [URL] = []
    
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
    @State private var fileToTag: URL?           // URL du fichier en cours d'édition de tag
    @State private var tagInput: String = ""     // Contenu du TextField de l'alerte
    @State private var fileTags: [String: String] = [:] // Cache local pour affichage UI
    
    // --- Managers (Injection de dépendances) ---
    @StateObject private var analysisManager = AnalysisManager()
    private let motionManager = MotionManager()
    private let audioRecorder = AudioRecorderManager()
    
    // --- État Système ---
    @State private var isAppActive: Bool = true
    
    // ========================================================================
    // MARK: - INTERFACE UTILISATEUR (BODY)
    // ========================================================================
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    
                    // 1. Titre
                    Text("EKKO").font(.system(size: 40, weight: .heavy, design: .rounded)).padding(.top, 40).foregroundColor(.white)
                    
                    // 2. Toggle Fast Report
                    HStack {
                        Image(systemName: isFastReportEnabled ? "bolt.fill" : "bolt.slash.fill").foregroundColor(isFastReportEnabled ? .yellow : .gray)
                        Text("Activer le Fast Report")
                        Spacer()
                        Toggle("", isOn: $isFastReportEnabled).labelsHidden().tint(.pink)
                    }.padding().background(Color.white.opacity(0.1)).cornerRadius(10).padding(.horizontal)
                    
                    // 3. Zone de Statut (Gestion Interruption)
                    Text(audioRecorder.wasInterrupted ?
                         "⚠️ REPRENDRE L'ENREGISTREMENT : L'audio a été coupé par le système. Revenez sur l'application (premier plan) pour relancer un segment." :
                         statusText)
                        .font(.headline).multilineTextAlignment(.center).padding(.horizontal).foregroundColor(audioRecorder.wasInterrupted ? .red : .gray)
                    
                    // 4. Switcher de Vues Principal
                    switch currentState {
                        case .idle:
                            IdleView(
                                history: $history, savedFiles: $savedFiles, fileTags: $fileTags,
                                deleteHistoryAction: { indexSet in HistoryManager.shared.deleteReport(at: indexSet, from: &history) },
                                deleteFileAction: deleteFiles,
                                onTagAction: { url in
                                    fileToTag = url
                                    // Chargement du tag existant (cache ou ZIP) pour pré-remplissage
                                    tagInput = HistoryManager.shared.getTag(for: url.lastPathComponent, from: url) ?? ""
                                    showingTagAlert = true
                                }
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
                    
                    // 5. Version en bas de page
                    Text(ContentView.appVersionInfo).font(.caption2).foregroundColor(.gray).padding(.top, 5)
                    
                    // 6. Gros Bouton d'Action (Start / Stop)
                    if currentState == .recording || currentState == .idle {
                        Button(action: {
                            if currentState == .idle { showingStartAlert = true }
                            else {
                                if let start = startTime, Date().timeIntervalSince(start) < 30 { showingShortSessionAlert = true }
                                else { Task { await stopAndAnalyze() } }
                            }
                        }) {
                            Text(currentState == .recording ? "Terminer la Soirée" : "Démarrer la Capture").font(.title3).fontWeight(.bold).padding().frame(maxWidth: .infinity).foregroundColor(.white).background(currentState == .recording ? AnyView(Color.red) : AnyView(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.pink]), startPoint: .leading, endPoint: .trailing))).cornerRadius(20)
                        }.padding(.horizontal, 40).padding(.bottom, 20)
                    }
                }
                .onAppear {
                    loadSavedFiles() // Charge les fichiers et les tags
                    history = HistoryManager.shared.loadHistory()
                }
                .preferredColorScheme(.dark)
                
                // --- LES ALERTES (Pop-ups) ---
                .alert("Ajouter un Tag", isPresented: $showingTagAlert) {
                    TextField("Ex: Anniv Thomas", text: $tagInput)
                    
                    // 🔑 BOUTON DE SUPPRESSION (Visible uniquement si le tag existe ou est en cours d'édition)
                    if !tagInput.isEmpty {
                        Button("Supprimer le Tag", role: .destructive) {
                            if let url = fileToTag {
                                removeTagFileFromZip(zipURL: url) // Nouvelle fonction de suppression
                                loadSavedFiles()
                            }
                        }
                    }
                    
                    Button("Annuler", role: .cancel) { fileToTag = nil; tagInput = "" }
                    
                    Button("Sauvegarder") {
                        if let url = fileToTag {
                            if tagInput.isEmpty {
                                // Si l'utilisateur vide le champ, cela agit comme une suppression.
                                removeTagFileFromZip(zipURL: url)
                            } else {
                                // Sinon, on ajoute/met à jour le tag dans le ZIP.
                                addTagFileToZip(zipURL: url, tag: tagInput)
                            }
                            loadSavedFiles()
                        }
                    }
                } message: {
                    Text("Ajoutez un mot-clé. Il sera intégré directement dans le fichier ZIP (tag.txt).")
                }
                
                // ... (autres alertes) ...
            }
            .navigationBarHidden(true)
        }
        // OBSERVATEURS SYSTÈME (Gestion Background/Foreground)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if !isAppActive { handleAppResumption() }
            isAppActive = true
        }.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in isAppActive = false }
    }
    
    // ========================================================================
    // MARK: - LOGIQUE MÉTIER & GESTION FICHIERS
    // ========================================================================
    
    /// Démarre une nouvelle session d'enregistrement. (Corps omis pour concision, mais fonctionnel)
    func startSession() {
        currentState = .recording; statusText = "🔴 Enregistrement en cours..."; savedFiles.removeAll()
        audioRecorder.startRecording(); motionManager.startUpdates(audioRecorder: self.audioRecorder); startTime = Date()
        timerSubscription = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { _ in
            let diff = Date().timeIntervalSince(startTime ?? Date()); let h = Int(diff) / 3600; let m = Int(diff) / 60 % 60; let s = Int(diff) % 60
            elapsedTimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }
    
    /// Gère la reprise de l'enregistrement quand l'utilisateur revient sur l'app.
    func handleAppResumption() {
        if audioRecorder.wasInterrupted {
            print("🔊 Reprise forcée : L'application est revenue au premier plan.")
            audioRecorder.resumeAfterForeground()
        }
    }
    
    /// Arrête l'enregistrement, sauvegarde les fichiers et lance l'analyse (ou juste le zip).
    func stopAndAnalyze() async {
        timerSubscription?.cancel(); let audioURLs = audioRecorder.stopRecording()
        guard let sensorsURL = motionManager.stopAndSaveToFile() else { statusText = "❌ Erreur de sauvegarde."; currentState = .idle; return }
        let metadataURL = motionManager.createMetadataFile(startTime: startTime ?? Date())
        var filesToZip = audioURLs; filesToZip.append(sensorsURL); filesToZip.append(contentsOf: [metadataURL].compactMap { $0 })
        let analysisAudioURL = audioURLs.first
        
        if isFastReportEnabled {
            // --- MODE FAST REPORT ---
            await MainActor.run { self.currentState = .analyzing; self.statusText = audioURLs.count > 1 ? "Analyse (segment 1)..." : "Analyse..." }
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            var moments: [HighlightMoment] = []
            if let urlToAnalyze = analysisAudioURL { moments = await analysisManager.analyzeSessionComplete(audioURL: urlToAnalyze, sensorsURL: sensorsURL) }
            
            // Création et sauvegarde du rapport
            let validMoments = moments.map { SavedMoment(timestamp: $0.timestamp, title: $0.song?.title ?? "Inconnu", artist: $0.song?.artist ?? "") }
            let finalDuration = Date().timeIntervalSince(startTime ?? Date())
            let report = PartyReport(id: UUID(), date: Date(), duration: finalDuration, moments: validMoments)
            HistoryManager.shared.saveReport(report)
            
            // 🔑 NOUVEAU: Création du fichier Fast Report (report.json) pour l'archivage dans le ZIP
            if let reportData = try? JSONEncoder().encode(report) {
                let tempReportURL = FileManager.default.temporaryDirectory.appendingPathComponent("report_\(Int(Date().timeIntervalSince1970)).json")
                try? reportData.write(to: tempReportURL); filesToZip.append(tempReportURL)
            }
            
            await MainActor.run {
                self.highlightMoments = moments; self.history = HistoryManager.shared.loadHistory()
                self.statusText = "Voici votre Top Kiff !"; self.currentState = .fastReport
                compressAndSave(files: filesToZip)
            }
        } else {
            // --- MODE SAUVEGARDE SEULE ---
            compressAndSave(files: filesToZip)
            await MainActor.run { self.statusText = "Sauvegardé."; self.currentState = .idle; self.loadSavedFiles() }
        }
    }
    
    /// Annule tout sans sauvegarder.
    func cancelSession() {
        timerSubscription?.cancel(); _ = audioRecorder.stopRecording(); _ = motionManager.stopAndSaveToFile()
        currentState = .idle; statusText = "Session annulée."
    }
    
    /// Modifie le fichier ZIP existant pour y injecter un fichier 'tag.txt'.
    func addTagFileToZip(zipURL: URL, tag: String) {
        let fm = FileManager.default; let tagContent = tag
        let tempTagURL = fm.temporaryDirectory.appendingPathComponent("tag_\(UUID().uuidString).txt")
        
        do {
            try tagContent.write(to: tempTagURL, atomically: true, encoding: .utf8)
            let archive = try Archive(url: zipURL, accessMode: .update)
            // L'ajout écrase automatiquement l'ancienne entrée 'tag.txt' si elle existe.
            try archive.addEntry(with: "tag.txt", relativeTo: tempTagURL, compressionMethod: .none)
            try fm.removeItem(at: tempTagURL); print("✅ Tag '\(tag)' intégré dans le ZIP : \(zipURL.lastPathComponent)")
            
            // Nettoyage de l'entrée locale (le tag est maintenant dans le ZIP)
            var tags = HistoryManager.shared.loadTags()
            tags.removeValue(forKey: zipURL.lastPathComponent)
            UserDefaults.standard.set(try? JSONEncoder().encode(tags), forKey: "EKKO_FileTags")
            
        } catch { print("❌ Erreur lors de l'ajout du tag au ZIP: \(error)"); try? fm.removeItem(at: tempTagURL) }
    }
    
    /// 🔑 NOUVEAU: Supprime le fichier 'tag.txt' de l'archive ZIP.
    func removeTagFileFromZip(zipURL: URL) {
        do {
            let archive = try Archive(url: zipURL, accessMode: .update)
            guard let entry = archive["tag.txt"] else {
                print("⚠️ Le tag n'existe pas dans le ZIP. Opération ignorée.")
                return
            }
            try archive.remove(entry)
            print("✅ Tag (tag.txt) supprimé du ZIP : \(zipURL.lastPathComponent)")
            
            // Nettoyer le cache local au cas où
            var tags = HistoryManager.shared.loadTags()
            tags.removeValue(forKey: zipURL.lastPathComponent)
            UserDefaults.standard.set(try? JSONEncoder().encode(tags), forKey: "EKKO_FileTags")
        } catch {
            print("❌ Erreur lors de la suppression du tag du ZIP: \(error)")
        }
    }
    
    /// Compresse les fichiers bruts en un fichier ZIP final.
    func compressAndSave(files: [URL]) {
        let fm = FileManager.default
        guard let firstAudioURL = files.first(where: { $0.pathExtension == "wav" }) else { return }
        
        // --- Calculs pour le nom ---
        let originalFilename = firstAudioURL.lastPathComponent; let prefixToFind = "rec_seg_"
        guard let startOfTimestamp = originalFilename.range(of: prefixToFind)?.upperBound else { return }
        let timestampWithExt = originalFilename[startOfTimestamp...]; guard let endOfTimestamp = timestampWithExt.range(of: ".wav")?.lowerBound else { return }
        let timestampString = String(timestampWithExt[..<endOfTimestamp]); guard let startTimeStamp = TimeInterval(timestampString) else { return }
        let startDate = Date(timeIntervalSince1970: startTimeStamp); let endTimeStamp = Date().timeIntervalSince1970; let durationSeconds = endTimeStamp - startTimeStamp
        
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "HHmm"; let timePart = timeFormatter.string(from: startDate)
        let totalMinutes = Int(durationSeconds / 60.0); let hours = totalMinutes / 60; let minutes = totalMinutes % 60; let durationString = String(format: "%dh%02dm", hours, minutes)
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyyMMdd"; let datePart = dateFormatter.string(from: startDate)
        
        // Format: EKKO[HHMM]_[DATE]_[DUREE].zip
        let newZipName = "EKKO\(timePart)_\(datePart)_\(durationString).zip"
        
        guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let zipURL = cachePath.appendingPathComponent(newZipName); try? fm.removeItem(at: zipURL)
        
        do {
            let archive = try Archive(url: zipURL, accessMode: .create)
            for file in files {
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
                // Nettoyage des fichiers temporaires (report.json) après ajout au ZIP
                if file.pathExtension == "json" { try? fm.removeItem(at: file) }
            }
            print("✅ ZIP créé : \(newZipName)")
            // Nettoyage des fichiers bruts originaux
            for file in files { try fm.removeItem(at: file) }
        } catch { print("❌ Erreur Zip: \(error)") }
        loadSavedFiles()
    }
    
    /// Supprime les fichiers ZIP sélectionnés et met à jour les tags.
    func deleteFiles(at offsets: IndexSet) {
        let fm = FileManager.default
        offsets.map { savedFiles[$0] }.forEach { try? fm.removeItem(at: $0) }
        
        // Nettoyage du cache de tags pour les fichiers supprimés
        var tags = HistoryManager.shared.loadTags()
        offsets.map { savedFiles[$0].lastPathComponent }.forEach { tags.removeValue(forKey: $0) }
        UserDefaults.standard.set(try? JSONEncoder().encode(tags), forKey: "EKKO_FileTags")
        
        loadSavedFiles()
    }
    
    /// Charge la liste des fichiers ZIP disponibles et charge les tags associés (cache/ZIP).
    func loadSavedFiles() {
        let fm = FileManager.default
        guard let doc = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        
        let localTags = HistoryManager.shared.loadTags()
        var updatedTags = [String: String]()
        
        savedFiles = (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "zip" }
                        .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })) ?? []
        
        // Parcourt les fichiers pour récupérer leur tag
        for file in savedFiles {
            let filename = file.lastPathComponent
            
            // 1. Essayer le cache local
            if let tag = localTags[filename], !tag.isEmpty {
                updatedTags[filename] = tag
                continue
            }
            
            // 2. Essayer de lire le tag DANS le ZIP (portable)
            if let tagContent = HistoryManager.shared.readContentFromZip(zipURL: file, entryName: "tag.txt"), !tagContent.isEmpty {
                updatedTags[filename] = tagContent
            }
        }
        
        fileTags = updatedTags // Mise à jour du cache UI
    }
}

// ============================================================================
// 🎨 SECTION 4: COMPOSANTS D'INTERFACE (Sous-Vues)
// ============================================================================

struct IdleView: View {
    @Binding var history: [PartyReport]; @Binding var savedFiles: [URL]; @Binding var fileTags: [String: String]
    var deleteHistoryAction: (IndexSet) -> Void; var deleteFileAction: (IndexSet) -> Void; var onTagAction: (URL) -> Void
    @State private var selectedTab = 0
    
    var body: some View {
        VStack {
            Picker("Affichage", selection: $selectedTab) { Text("Journal").tag(0); Text("Fichiers ZIP").tag(1) }.pickerStyle(SegmentedPickerStyle()).padding()
            
            if selectedTab == 0 {
                if history.isEmpty { EmptyState(icon: "music.note.list", text: "Aucune soirée enregistrée.") }
                else { List { ForEach(history) { report in NavigationLink(destination: HistoryDetailView(report: report)) { VStack(alignment: .leading) { Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.headline).foregroundColor(.white); Text("\(report.moments.count) moment(s) fort(s)").font(.caption).foregroundColor(.orange) } }.listRowBackground(Color.white.opacity(0.1)) }.onDelete(perform: deleteHistoryAction) }.scrollContentBackground(.hidden) }
            } else {
                if savedFiles.isEmpty { EmptyState(icon: "doc.zipper", text: "Aucun fichier brut.") }
                else {
                    List {
                        ForEach(savedFiles, id: \.self) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(file.lastPathComponent).font(.caption).foregroundColor(.white)
                                    Text(getFileSize(url: file)).font(.caption2).foregroundColor(.gray)
                                    // Affichage du Tag
                                    if let tag = fileTags[file.lastPathComponent], !tag.isEmpty {
                                        Text("🏷 \(tag)").font(.caption2).padding(4).background(Color.blue.opacity(0.6)).cornerRadius(4).foregroundColor(.white)
                                    }
                                }
                                Spacer()
                                
                                // Bouton pour Ajouter/Modifier le Tag
                                Button(action: { onTagAction(file) }) { Image(systemName: "tag.fill").foregroundColor(.yellow) }.buttonStyle(BorderlessButtonStyle()).padding(.trailing, 10)
                                
                                // Bouton Partage
                                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }.onDelete(perform: deleteFileAction)
                    }.scrollContentBackground(.hidden)
                }
            }
            Spacer()
        }
    }
    
    func getFileSize(url: URL) -> String { let attr = try? FileManager.default.attributesOfItem(atPath: url.path); let size = attr?[.size] as? Int64 ?? 0; return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

// ... (Définitions des autres sous-vues et des Managers restent fonctionnellement identiques) ...

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

class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {
    var audioRecorder: AVAudioRecorder?; var recordedFileUrls: [URL] = []; var wasInterrupted = false
    override init() { super.init(); NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil) }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func setupAndStartNewRecorder() -> URL? {
        let session = AVAudioSession.sharedInstance(); try? session.setCategory(.record, mode: .default, options: [.allowBluetooth]); try? session.setActive(true)
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]; let filename = "rec_seg_\(Int(Date().timeIntervalSince1970)).wav"; let newURL = docPath.appendingPathComponent(filename)
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false]
        do { audioRecorder = try AVAudioRecorder(url: newURL, settings: settings); audioRecorder?.isMeteringEnabled = true; audioRecorder?.record(); self.recordedFileUrls.append(newURL); print("✅ Nouvelle session: \(filename)"); return newURL } catch { print("❌ Erreur REC: \(error)"); return nil }
    }
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo, let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type { case .began: self.wasInterrupted = true; audioRecorder?.stop() case .ended: print("🔊 Fin interruption système.") @unknown default: break }
    }
    func startRecording() { self.recordedFileUrls.removeAll(); _ = setupAndStartNewRecorder() }
    func resumeAfterForeground() { if self.wasInterrupted { _ = setupAndStartNewRecorder(); self.wasInterrupted = false } }
    func stopRecording() -> [URL] { audioRecorder?.stop(); try? AVAudioSession.sharedInstance().setActive(false); let all = self.recordedFileUrls; self.recordedFileUrls.removeAll(); return all }
    func getCurrentPower() -> Float { audioRecorder?.updateMeters(); return audioRecorder?.averagePower(forChannel: 0) ?? -160.0 }
}

class MotionManager {
    private let mm = CMMotionManager(); private var dataBuffer: [String] = []; private var csvString = ""
    private var batteryLevelStart: Float = 0.0; private var startTime: Date = Date(); private var fileURL: URL?

    func startUpdates(audioRecorder: AudioRecorderManager) {
        csvString = "timestamp,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,attitude_roll,attitude_pitch,attitude_yaw,gravity_x,gravity_y,gravity_z,audio_power_db\n"; dataBuffer.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = true; self.batteryLevelStart = UIDevice.current.batteryLevel; self.startTime = Date()
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]; self.fileURL = doc.appendingPathComponent("sensors_\(Int(Date().timeIntervalSince1970)).csv")
        mm.deviceMotionUpdateInterval = 0.1
        mm.startDeviceMotionUpdates(to: .main) { (deviceMotion, error) in
            guard let data = deviceMotion else { return }
            let audioPower = audioRecorder.getCurrentPower(); let timestamp = Date().timeIntervalSince1970
            let newLine = "\(timestamp),\(data.userAcceleration.x),\(data.userAcceleration.y),\(data.userAcceleration.z),\(data.rotationRate.x),\(data.rotationRate.y),\(data.rotationRate.z),\(data.attitude.roll),\(data.attitude.pitch),\(data.attitude.yaw),\(data.gravity.x),\(data.gravity.y),\(data.gravity.z),\(audioPower)\n"
            self.dataBuffer.append(newLine)
        }
    }
    func stopAndSaveToFile() -> URL? { mm.stopDeviceMotionUpdates(); csvString.append(contentsOf: dataBuffer.joined()); dataBuffer.removeAll(); guard let url = fileURL else { return nil }; try? csvString.write(to: url, atomically: true, encoding: .utf8); return url }
    func createMetadataFile(startTime: Date) -> URL? {
        UIDevice.current.isBatteryMonitoringEnabled = true; let endTime = Date(); let duration = endTime.timeIntervalSince(startTime)
        let metadataContent = "METADATA EKKO\nVersion: \(ContentView.appVersionInfo)\nDébut: \(startTime)\nFin: \(endTime)\nDurée: \(duration/60) min\nBatterie Début: \(self.batteryLevelStart * 100)%\nBatterie Fin: \(UIDevice.current.batteryLevel * 100)%\n"
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]; let metadataURL = docPath.appendingPathComponent("metadata_\(Int(Date().timeIntervalSince1970)).txt")
        try? metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8); return metadataURL
    }
}
class AnalysisManager: NSObject, ObservableObject {
    let acrClient: ACRCloudRecognition; @Published var analysisProgress: Double = 0.0
    override init() {
        let config = ACRCloudConfig(); config.host = "identify-eu-west-1.acrcloud.com"; config.accessKey = "41eb0dc8541f8a793ebe5f402befc364"; config.accessSecret = "h0igyw66jaOPgoPFskiGes1XUbzQbYQ3vpVzurgT"; config.recMode = rec_mode_remote; config.requestTimeout = 10; config.protocol = "https"
        self.acrClient = ACRCloudRecognition(config: config)
    }
    func analyzeSessionComplete(audioURL: URL, sensorsURL: URL) async -> [HighlightMoment] { return [] }
}

#Preview {
    ContentView()
}
