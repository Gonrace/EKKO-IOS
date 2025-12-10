// ============================================================================
// 🧠 MANAGER STORAGE
// ============================================================================

import Foundation
import ZIPFoundation

class StorageManager {
    static let shared = StorageManager()
    
    func loadSavedFiles() -> [URL] {
        let fm = FileManager.default
        guard let doc = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        return (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })) ?? []
    }
    
    func deleteFile(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            print("✅ Fichier supprimé : \(url.lastPathComponent)")
        } catch {
            ErrorManager.shared.handle(.fileSystem("Suppression de \(url.lastPathComponent) - \(error.localizedDescription)"))
        }
    }
    
    func compressAndSave(files: [URL], completion: @escaping () -> Void) {
            let fm = FileManager.default
            
            // 1. 🔥 ON CHERCHE LE CSV AU LIEU DE L'AUDIO (Plus robuste)
            // On cherche un fichier qui finit par ".csv" dans la liste
            let csvURL = files.first(where: { $0.pathExtension == "csv" })
            
            // 2. Extraction de la date de début
            var startTime = Date() /// Par defaut Maintenant si on ne trouve pas
            if let url = csvURL {
                // Le nom est du type : "sensors_173159203.csv"
                let filename = url.deletingPathExtension().lastPathComponent
                let components = filename.components(separatedBy: "_")
                
                // On prend la partie après le "_" (le timestamp)
                if let lastComponent = components.last, let ts = TimeInterval(lastComponent) {
                    startTime = Date(timeIntervalSince1970: ts)
                }
            }
            
            // 3. Date de fin (Maintenant)
            let endTime = Date()
            
            // 4. Formatage du nom : EKKO_YYYYMMDD_HHMM_HHMM
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd" // 20251212
            
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HHmm"     // 1430
            
            let dateString = dateFormatter.string(from: startTime)
            let startString = timeFormatter.string(from: startTime)
            let endString = timeFormatter.string(from: endTime)
            
            // Résultat : EKKO_20251212_1430_1545.zip
            let newZipName = "EKKO_\(dateString)_\(startString)_\(endString).zip"
            
            // 5. Chemin du dossier Cache
            guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                ErrorManager.shared.handle(.fileSystem("ZIP : Cache inaccessible"))
                return
            }
            
            let zipURL = cachePath.appendingPathComponent(newZipName)
            
            // 6. Création du ZIP
            do {
                try? fm.removeItem(at: zipURL) // Nettoyage préventif
                
                let archive = try Archive(url: zipURL, accessMode: .create)
                for file in files {
                    try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
                }
                
                // Nettoyage des fichiers originaux après compression
                for file in files {
                    try? fm.removeItem(at: file)
                }
                
                completion()
            } catch {
                ErrorManager.shared.handle(.fileSystem("ZIP : \(error.localizedDescription)"))
            }
        }
}
