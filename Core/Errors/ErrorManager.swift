import SwiftUI
import os // Pour les logs système

// ============================================================================
// 1️⃣ DOMAINES D'ERREURS HIÉRARCHIQUES
// ============================================================================

enum AudioError: LocalizedError {
    case permissionDenied
    case recordingFailed(underlying: Error?) // Capture l'erreur native
    case interruption
    case mergeFailed
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Accès au microphone refusé."
        case .recordingFailed: return "Échec de l'enregistrement audio."
        case .interruption: return "L'enregistrement a été coupé par le système (appel/Siri)."
        case .mergeFailed: return "Impossible de fusionner les segments audio."
        }
    }
}

enum SensorError: LocalizedError {
    case notAvailable
    case dataWriteFailed
    case criticalFileSetup // Erreur lors de la création initiale du CSV
    
    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Capteurs de mouvement non disponibles."
        case .dataWriteFailed: return "Échec de sauvegarde des données capteurs."
        case .criticalFileSetup: return "Erreur critique de création du fichier de capteurs."
        }
    }
}

enum AnalysisError: LocalizedError {
    case networkUnreachable
    case apiError(String)
    case noMusicFound
    case parsingFailed
    
    var errorDescription: String? {
        switch self {
        case .networkUnreachable: return "Pas de connexion Internet."
        case .apiError(let msg): return "Erreur Serveur d'Analyse : \(msg)"
        case .noMusicFound: return "Aucune musique détectée."
        case .parsingFailed: return "Lecture des résultats impossible."
        }
    }
}

// ============================================================================
// 2️⃣ L'ERREUR GLOBALE (Wrapper)
// ============================================================================

enum AppError: LocalizedError, Identifiable {
    var id: String { UUID().uuidString }
    
    case audio(AudioError)
    case sensor(SensorError)
    case analysis(AnalysisError)
    case fileSystem(String) // Pour ZIP, JSON, Historique, ou autres I/O
    case generic(String)
    
    var errorDescription: String? {
        switch self {
        case .audio(let e): return e.errorDescription
        case .sensor(let e): return e.errorDescription
        case .analysis(let e): return e.errorDescription
        case .fileSystem(let msg): return "Erreur Fichier/Système : \(msg)"
        case .generic(let msg): return msg
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .audio(.permissionDenied): return "Activez le microphone dans les Réglages iOS."
        case .fileSystem: return "Libérez de l'espace de stockage et réessayez."
        case .analysis(.networkUnreachable): return "Vérifiez votre connexion Internet."
        default: return nil
        }
    }
    
    // 🔥 NOUVEAU : Niveau de sévérité pour décider de l'action UI
    var severity: ErrorSeverity {
        switch self {
        case .audio(.permissionDenied), .sensor(.criticalFileSetup): return .critical
        case .analysis(.noMusicFound): return .info // Pas besoin de popup
        case .audio(.interruption): return .warning
        default: return .error
        }
    }
}

enum ErrorSeverity {
    case info, warning, error, critical
}

// ============================================================================
// 3️⃣ LE MANAGER (Singleton et Log)
// ============================================================================

class ErrorManager: ObservableObject {
    // Rendre l'instance unique accessible par tous les managers
    static let shared = ErrorManager()
    
    @Published var currentError: AppError?
    @Published var showError = false
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ekko", category: "ErrorManager")
    
    private init() {} // Empêche l'initialisation multiple
    
    func handle(_ error: AppError) {
        let message = error.errorDescription ?? "Erreur inconnue"
        let suggestion = error.recoverySuggestion ?? ""
        
        // Log console (utilise le logger, plus performant que print)
        switch error.severity {
        case .critical: logger.fault("🛑 CRITICAL: \(message) -> \(suggestion)")
        case .error: logger.error("❌ ERROR: \(message)")
        case .warning: logger.warning("⚠️ WARNING: \(message)")
        case .info: logger.info("ℹ️ INFO: \(message)")
        }
        
        // Décision UI
        DispatchQueue.main.async {
            if error.severity != .info {
                self.currentError = error
                self.showError = true
            }
        }
    }
    
    func logWarning(_ message: String) {
        logger.warning("⚠️ WARNING: \(message)")
    }
    
    // Pour attraper des erreurs Error natives et les router
    func handle(_ error: Error) {
        if let appError = error as? AppError {
            handle(appError)
        } else {
            handle(.generic("Erreur système non gérée : \(error.localizedDescription)"))
        }
    }
}
