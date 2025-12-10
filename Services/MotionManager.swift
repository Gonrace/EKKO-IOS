// ============================================================================
// 📊 MANAGER CAPTEURS
// ============================================================================


import Foundation
import CoreMotion
import UIKit

class MotionManager {
    private let mm = CMMotionManager()
    
    // Analyze BPM Player
    private let rhythmAnalyzer = RhythmAnalyzer()
    
    // On ne garde pas tout l'historique, juste un petit tampon
    private var writeBuffer: String = ""
    private var bufferCount = 0
    private let bufferLimit = AppConfig.Sensors.bufferSize
    private var fileHandle: FileHandle?
    private var fileURL: URL?

    // Pour afficher le BPM en direct sur l'app (fonction de test uniquement)
    var onLiveBPMUpdate: ((Int) -> Void)?
    
    // Métadonnées
    private var batteryLevelStart: Float = 0.0
    private var startTime: Date = Date()

    func startUpdates(audioRecorder: AudioRecorderManager) {
        // 1. Préparation du fichier
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = doc.appendingPathComponent("sensors_\(Int(Date().timeIntervalSince1970)).csv")
        
        // 2. En-tête CSV
        let header = "timestamp,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,attitude_roll,attitude_pitch,attitude_yaw,gravity_x,gravity_y,gravity_z,audio_power_db,proximity,bpm\n"
        
        guard let url = fileURL else { return }
        
        // 3. Ouverture du pipe vers le fichier (FileHandle)
        do {
            // On écrit l'en-tête (crée le fichier)
            try header.write(to: url, atomically: true, encoding: .utf8)
            // On ouvre le robinet pour ajouter des données à la suite
            self.fileHandle = try FileHandle(forWritingTo: url)
            self.fileHandle?.seekToEndOfFile()
        } catch {
            ErrorManager.shared.handle(.sensor(.criticalFileSetup))
            return
        }

        // 4. Initialisation Capteurs
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.batteryLevelStart = UIDevice.current.batteryLevel
        self.startTime = Date()
        
        // Activation Proximité
        UIDevice.current.isProximityMonitoringEnabled = true
        
        mm.deviceMotionUpdateInterval = AppConfig.Sensors.updateInterval
        
        mm.startDeviceMotionUpdates(to: .main) { [weak self] (deviceMotion, error) in
            guard let self = self, let data = deviceMotion else { return }
            
            let currentBPM = self.rhythmAnalyzer.process(
                            x: data.userAcceleration.x,
                            y: data.userAcceleration.y,
                            z: data.userAcceleration.z
                        )
            if currentBPM > 0 { print("🥁 BPM DÉTECTÉ : \(currentBPM)") }

            let audioPower = audioRecorder.getCurrentPower()
            let timestamp = Date().timeIntervalSince1970
            let proximity = UIDevice.current.proximityState ? 1 : 0
            
            // 5. Création de la ligne
            let line = "\(timestamp),\(data.userAcceleration.x),\(data.userAcceleration.y),\(data.userAcceleration.z),\(data.rotationRate.x),\(data.rotationRate.y),\(data.rotationRate.z),\(data.attitude.roll),\(data.attitude.pitch),\(data.attitude.yaw),\(data.gravity.x),\(data.gravity.y),\(data.gravity.z),\(audioPower),\(proximity),\(currentBPM)\n"
            
            // 6. Ajout au petit tampon
            self.writeBuffer.append(line)
            self.bufferCount += 1
            
            // 7. Flush sur le disque tous les échantillons
            if self.bufferCount >= self.bufferLimit {
                self.flushToDisk()
            }
            
            // Callback UI (pour afficher le BPM)
            self.onLiveBPMUpdate?(currentBPM)
        }
    }
    
    // Fonction privée pour vider le tampon
    private func flushToDisk() {
        if let data = writeBuffer.data(using: .utf8) {
            // Écriture physique
            try? fileHandle?.write(contentsOf: data)
        }
        // Reset du tampon
        writeBuffer = ""
        bufferCount = 0
    }
    
    func stopAndSaveToFile() -> URL? {
        mm.stopDeviceMotionUpdates()
        UIDevice.current.isProximityMonitoringEnabled = false
        
        // 8. IMPORTANT : Écrire ce qui reste dans le tampon avant de fermer
        flushToDisk()
        
        // Fermeture propre du fichier
        try? fileHandle?.close()
        fileHandle = nil
        
        return fileURL
    }
    
    // REMPLACER LA FONCTION createMetadataFile EXISTANTE PAR CELLE-CI :
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
            
            do {
                try metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8)
                return metadataURL
            } catch {
                ErrorManager.shared.handle(.fileSystem("Création metadata : \(error.localizedDescription)"))
                return nil
            }
        }
}
