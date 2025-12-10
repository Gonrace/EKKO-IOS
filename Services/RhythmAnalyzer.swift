// ============================================================================
// 📚 RYTHME BPM ANALYZER
// ============================================================================

import Foundation
import Accelerate

class RhythmAnalyzer {
    
    // Buffer circulaire qui garde toujours les dernières 20 secondes de data
    private var buffer: [Double] = []
    private let limit = AppConfig.BPM.windowSize // 1000 points (20s * 50Hz)
    
    // Optimisation : On ne recalcule pas le BPM à chaque milliseconde
    private var frameCounter = 0
    private var lastCalculatedBPM: Int = 0
    
    /// Ajoute une nouvelle mesure (x, y, z) et retourne le BPM actuel (mis à jour chaque seconde)
    func process(x: Double, y: Double, z: Double) -> Int {
        
        // 1. Calcul de l'énergie (Magnitude sans gravité)
        let magnitude = sqrt(pow(x, 2) + pow(y, 2) + pow(z, 2))
        let cleanMagnitude = abs(magnitude - 1.0)
        
        // 2. Ajout au buffer glissant
        buffer.append(cleanMagnitude)
        if buffer.count > limit {
            buffer.removeFirst() // On oublie la donnée la plus vieille
        }
        
        // 3. Gestion de la fréquence de calcul
        frameCounter += 1
        
        // On recalcule le BPM seulement toutes les 50 frames (1 fois par seconde)
        // ET seulement si on a rempli au moins la moitié du buffer (10 secondes de data)
        if frameCounter >= Int(AppConfig.Sensors.frequency) {
            frameCounter = 0
            if buffer.count >= (limit / 2) {
                lastCalculatedBPM = calculateBPM()
            }
        }
        
        return lastCalculatedBPM
    }
    
    /// L'algorithme mathématique pur
    private func calculateBPM() -> Int {
        // A. Vérifier si ça bouge assez (Moyenne)
        let sum = buffer.reduce(0, +)
        let average = sum / Double(buffer.count)
        
        // Si c'est trop calme, on renvoie 0 direct
        if average < AppConfig.BPM.minMovementThreshold { return 0 }
        
        // B. Comptage de pics (Zero-Crossing adaptatif)
        var peaks = 0
        var isAbove = false
        // Le seuil pour un "battement" est 20% au-dessus de la moyenne de l'énergie actuelle
        let threshold = average * 1.2
        
        for val in buffer {
            if val > threshold {
                if !isAbove {
                    peaks += 1
                    isAbove = true
                }
            } else {
                isAbove = false
            }
        }
        
        // C. Conversion Mathématique
        // Durée réelle du buffer en secondes (ex: 950 points / 50Hz = 19s)
        let durationInSeconds = Double(buffer.count) / AppConfig.Sensors.frequency
        
        // Formule : (Nb Pics / Durée) * 60 secondes
        let rawBpm = (Double(peaks) / durationInSeconds) * 60.0
        
        // D. Filtrage (On ne garde que ce qui ressemble à de la musique)
        if rawBpm < AppConfig.BPM.min || rawBpm > AppConfig.BPM.max {
            return 0
        }
        
        return Int(rawBpm)
    }
}
