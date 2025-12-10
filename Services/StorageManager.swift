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
        
        guard let firstAudioURL = files.first(where: { $0.pathExtension == "wav" || $0.pathExtension == "m4a" }) else {
            ErrorManager.shared.handle(.fileSystem("ZIP : Aucun fichier audio source trouvé"))
            return
        }
        
        let originalFilename = firstAudioURL.lastPathComponent
        // ... (Logique d'extraction de date simplifiée pour l'exemple) ...
        let timestamp = Date().timeIntervalSince1970
        let newZipName = "EKKO_\(Int(timestamp)).zip"
        
        guard let cachePath = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            ErrorManager.shared.handle(.fileSystem("ZIP : Cache inaccessible"))
            return
        }
        
        let zipURL = cachePath.appendingPathComponent(newZipName)
        
        do {
            try? fm.removeItem(at: zipURL)
            let archive = try Archive(url: zipURL, accessMode: .create)
            for file in files {
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent())
            }
            
            // Cleanup
            for file in files {
                try? fm.removeItem(at: file)
            }
            completion()
        } catch {
            ErrorManager.shared.handle(.fileSystem("ZIP : \(error.localizedDescription)"))
        }
    }
}
