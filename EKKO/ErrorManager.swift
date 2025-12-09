import SwiftUI

enum AppError: LocalizedError {
    case audioRecordingFailed(String)
    case sensorDataFailed
    case fileWriteFailed(String)
    case audioMergeFailed
    case analysisFailed(String)
    case historyLoadFailed
    case zipCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .audioRecordingFailed(let details):
            return "Impossible d'enregistrer l'audio : \(details)"
        case .sensorDataFailed:
            return "Échec de la sauvegarde des capteurs"
        case .fileWriteFailed(let file):
            return "Impossible d'écrire le fichier : \(file)"
        case .audioMergeFailed:
            return "Échec de la fusion audio"
        case .analysisFailed(let reason):
            return "Analyse échouée : \(reason)"
        case .historyLoadFailed:
            return "Impossible de charger l'historique"
        case .zipCreationFailed(let details):
            return "Erreur création ZIP : \(details)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .audioRecordingFailed:
            return "Vérifiez les autorisations micro dans Réglages"
        case .sensorDataFailed:
            return "Redémarrez l'application"
        case .fileWriteFailed:
            return "Libérez de l'espace de stockage"
        case .audioMergeFailed:
            return "Les segments audio seront sauvegardés séparément"
        case .analysisFailed:
            return "Réessayez plus tard ou désactivez Fast Report"
        case .historyLoadFailed:
            return "L'historique sera recréé automatiquement"
        case .zipCreationFailed:
            return "Vérifiez l'espace disponible et réessayez"
        }
    }
}

class ErrorManager: ObservableObject {
    @Published var currentError: AppError?
    @Published var showError = false
    
    func handle(_ error: AppError) {
        print("❌ ERREUR: \(error.localizedDescription)")
        if let recovery = error.recoverySuggestion {
            print("💡 SOLUTION: \(recovery)")
        }
        
        DispatchQueue.main.async {
            self.currentError = error
            self.showError = true
        }
    }
    
    func logWarning(_ message: String) {
        print("⚠️ ATTENTION: \(message)")
    }
}
