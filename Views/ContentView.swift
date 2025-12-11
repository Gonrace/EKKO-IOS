import SwiftUI

struct ContentView: View {
    
    // 🔥 Le ViewModel est maintenant le seul maître à bord
    @StateObject private var viewModel = SessionViewModel()
    
    // On garde ErrorManager pour les popups globales
    @StateObject private var errorManager = ErrorManager.shared
    
    // États purement UI (Navigation, Toggle)
    @State private var isFastReportEnabled: Bool = true
    @State private var showingStartAlert = false
    @State private var showingShortSessionAlert = false
    @State private var isAppActive = true
    
    var mainButtonBackground: some View {
        if viewModel.state == .recording {
            return AnyView(Color.red)
        } else {
            return AnyView(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.pink]), startPoint: .leading, endPoint: .trailing))
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    
                    // HEADER
                    Text("EKKO")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .padding(.top, 40)
                        .foregroundColor(.white)
                    
                    // TOGGLE FAST REPORT
                    HStack {
                        Image(systemName: isFastReportEnabled ? "bolt.fill" : "bolt.slash.fill")
                            .foregroundColor(isFastReportEnabled ? .yellow : .gray)
                        Text("Activer le Fast Report")
                        Spacer()
                        Toggle("", isOn: $isFastReportEnabled).labelsHidden().tint(.pink)
                    }
                    .padding().background(Color.white.opacity(0.1)).cornerRadius(10).padding(.horizontal)
                    
                    // STATUS TEXT
                    Text(viewModel.statusText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .foregroundColor(.gray)
                    
                    // --- ÉCRANS (Basés sur l'état du ViewModel) ---
                    switch viewModel.state {
                    case .idle:
                        IdleView(
                            history: $viewModel.history,
                            savedFiles: $viewModel.savedFiles,
                            deleteHistoryAction: { indexSet in
                                // Assurez-vous que HistoryManager supporte ce modèle
                                HistoryManager.shared.deleteReport(at: indexSet, from: &viewModel.history)
                            },
                            deleteFileAction: { indexSet in
                                // Suppression via StorageManager
                                indexSet.forEach { index in
                                    if index < viewModel.savedFiles.count {
                                        StorageManager.shared.deleteFile(url: viewModel.savedFiles[index])
                                    }
                                }
                                // On rafraichit la liste
                                viewModel.refreshData()
                            }
                        )
                        
                    case .recording:
                        RecordingView(elapsedTimeString: $viewModel.elapsedTimeString)
                        
                    case .analyzing:
                        // Lier à la progression du ViewModel si elle est disponible
                        AnalyzingView(progress: 0.5)
                        
                    case .fastReport:
                        // ⚠️ NOTE: La FastReportView a été modifiée pour recevoir le PartyReport complet
                        // Le ViewModel doit donc fournir ce rapport, et FastReportView doit être adapté.
                        FastReportView(moments: $viewModel.highlightMoments, onDone: {
                            viewModel.resetToIdle()
                        })
                    }
                    
                    // FOOTER
                    Text(ContentView.appVersionInfo)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.top, 5)
                    
                    // BOUTON ACTION PRINCIPAL
                    if viewModel.state == .recording || viewModel.state == .idle {
                        Button(action: {
                            if viewModel.state == .idle {
                                showingStartAlert = true
                            } else {
                                // Vérification de la durée (logique UI)
                                if let start = viewModel.startTime, Date().timeIntervalSince(start) < AppConfig.Timing.minSessionDuration {
                                    showingShortSessionAlert = true
                                } else {
                                    Task { await viewModel.stopAndAnalyze(isFastReportEnabled: isFastReportEnabled) }
                                }
                            }
                        }) {
                            Text(mainButtonText) // Utilisation de la propriété simple
                                .font(.title3).fontWeight(.bold)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.white)
                                .background(mainButtonBackground) // Utilisation de la propriété simple
                                .cornerRadius(20)
                        }
                        .padding(.horizontal, 40).padding(.bottom, 20)
                    }
                }
                
                // --- ALERTES ---
                
                // Alertes de Session
                .alert("Avant de commencer", isPresented: $showingStartAlert) {
                    Button("C'est parti !", role: .cancel) { viewModel.startSession() }
                } message: { Text("Verrouillez l'écran et activez le Mode Avion.") }
                
                .alert("Déjà fini ?", isPresented: $showingShortSessionAlert) {
                    Button("Continuer", role: .cancel) {}
                    Button("Arrêter sans sauvegarder", role: .destructive) { viewModel.cancelSession() }
                } message: { Text("Moins de 30 secondes ? C'est trop court.") }
                
                // Gestion centralisée des erreurs
                .alert(errorManager.currentError?.localizedDescription ?? "Erreur",
                       isPresented: $errorManager.showError,
                       presenting: errorManager.currentError) { error in
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
        // Gestion foreground/background
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if !isAppActive {
                // Ici, vous pourriez appeler viewModel.handleAppResumption() si nécessaire
            }
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppActive = false
        }
        .onAppear {
            viewModel.refreshData()
        }
    }
    
    // MARK: - Propriétés Calculées pour l'UI (Stabilité du Compilateur)
    
    // 🔥 Correction 1 : Extrait la logique de background
    var mainButtonBackground: some View {
        if viewModel.state == .recording {
            return AnyView(Color.red)
        } else {
            return AnyView(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.pink]), startPoint: .leading, endPoint: .trailing))
        }
    }
    
    // 🔥 Correction 2 : Extrait la logique du texte du bouton (bonne pratique)
    var mainButtonText: String {
        viewModel.state == .recording ? "Terminer la Soirée" : "Démarrer la Capture"
    }
    
    // MARK: - Propriétés Statiques
    
    static var appVersionInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Inconnu"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Inconnu"
        return "Version \(version) (Build \(build))"
    }
}

#Preview {
    ContentView()
}
