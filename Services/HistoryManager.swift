// ============================================================================
// 📚 MANAGER HISTORY
// ============================================================================

import Foundation
import SwiftUI

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

