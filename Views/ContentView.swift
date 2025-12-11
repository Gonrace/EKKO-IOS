import SwiftUI
import UIKit // Nécessaire pour UIApplication

struct ContentView: View {
    
    // ViewModel et ErrorManager
    @StateObject private var viewModel = SessionViewModel()
    @StateObject private var errorManager = ErrorManager.shared
    
    // États purement UI (Navigation, Toggle)
    @State private var isFastReportEnabled: Bool = true
    @State private var showingStartAlert = false
    @State private var showingShortSessionAlert = false
    @State private var isAppActive = true
    
    // ==========================================
    // PROPRIÉTÉS CALCULÉES (FIX COMPILATION)
    // ==========================================

    var mainButtonText: String {
        return viewModel.state == .recording ? "Terminer la Soirée" : "Démarrer la Capture"
    }

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
                        // NOTE: IdlevView non fournie, supposée exister
                        IdleView(
                            history: $viewModel.history,
                            savedFiles: $viewModel.savedFiles,
                            deleteHistoryAction: { indexSet in
                                HistoryManager.shared.deleteReport(at: indexSet, from: &viewModel.history)
                            },
                            deleteFileAction: { indexSet in
                                indexSet.forEach { index in
                                    if index < viewModel.savedFiles.count {
                                        StorageManager.shared.deleteFile(url: viewModel.savedFiles[index])
                                    }
                                }
                                viewModel.refreshData()
                            }
                        )
                        
                    case .recording:
                        // NOTE: RecordingView non fournie, supposée exister
                        RecordingView(elapsedTimeString: $viewModel.elapsedTimeString)
                        
                    case .analyzing:
                        // NOTE: AnalyzingView non fournie, supposée exister
                        AnalyzingView(progress: 0.5)
                        
                    case .fastReport:
                        // On vérifie que le rapport est bien généré avant l'affichage
                        if let report = viewModel.fastReportInstance {
                            FastReportView(report: report, onDone: {
                                viewModel.resetToIdle()
                            })
                        } else {
                            Text("Erreur: Rapport final manquant")
                        }
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
                                if let start = viewModel.startTime, Date().timeIntervalSince(start) < AppConfig.Timing.minSessionDuration {
                                    showingShortSessionAlert = true
                                } else {
                                    Task { await viewModel.stopAndAnalyze(isFastReportEnabled: isFastReportEnabled) }
                                }
                            }
                        }) {
                            Text(mainButtonText)
                                .font(.title3).fontWeight(.bold)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.white)
                                .background(mainButtonBackground)
                                .cornerRadius(20)
                        }
                        .padding(.horizontal, 40).padding(.bottom, 20)
                    }
                }
                
                // --- ALERTES ---
                
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
             isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppActive = false
        }
        .onAppear {
            viewModel.refreshData()
        }
    } // <-- Fermeture du var body: some View
    
    // 🔥 CORRECTION : Position correcte pour la propriété statique
    static var appVersionInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Inconnu"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Inconnu"
        return "Version \(version) (Build \(build))"
    }

} // <-- Fermeture de la struct ContentView

#Preview {
    ContentView()
}
