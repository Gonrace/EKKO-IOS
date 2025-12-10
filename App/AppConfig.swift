import Foundation

struct AppConfig {
    
// ==========================================
// ⏱️ TEMPS & DURÉES
// ==========================================
    struct Timing {
        /// Durée de la fenêtre d'analyse pour un moment fort (Audio, Capteurs, BPM)
        static let analysisWindowSeconds: Double = 20.0
        
        /// Durée minimale d'enregistrement pour accepter de sauvegarder
        static let minSessionDuration: TimeInterval = 30.0
        
        /// Temps minimum entre deux moments forts (pour éviter le chevauchement)
        static let minTimeBetweenPeaks: Double = 60.0
                
        /// Temps minimum pour accepter la MÊME musique une 2ème fois
        static let minTimeBetweenSameSong: Double = 600.0
    }
    
// ==========================================
// 📡 CAPTEURS & CSV (La source de données)
// ==========================================
    struct Sensors {
        /// Fréquence d'enregistrement (Hz).
        static let frequency: Double = 50.0
    
        /// Intervalle de mise à jour (calculé automatiquement : 0.1s pour 10Hz)
        static let updateInterval: Double = 1.0 / frequency
        
        /// On veut écrire sur le disque toutes les X secondes (ex: 5 secondes)
        /// pour ne pas surcharger le processeur avec des écritures trop fréquentes.
        static let writeIntervalSeconds: Double = 5.0
        
        /// Nombre de lignes à garder en mémoire tampon avant d'écrire sur le disque
        static let bufferSize: Int = Int(frequency*writeIntervalSeconds)
    }

// ==========================================
// 🥁 ANALYSE RYTHMIQUE (BPM Player vs Music)
// ==========================================
    struct BPM {
            static let windowSize: Int = Int(Timing.analysisWindowSeconds * Sensors.frequency)
            
            /// Plage technique de détection (pour le RhythmAnalyzer)
            static let min: Double = 60.0
            static let max: Double = 180.0
            
            /// Plage pour appliquer le BONUS (Ce que tu considères comme "Danse")
            static let bonusRangeMin: Double = 90.0  // ex: En dessous de 90, pas de bonus
            static let bonusRangeMax: Double = 175.0 // ex: Au dessus de 175, c'est du bruit
            
            static let minMovementThreshold: Double = 0.05
            static let rhythmBonusFactor: Double = 1.2
    }
    
    
// ==========================================
// 🧮 ALGORITHME "PARTY POWER" (Les Pondérations)
// ==========================================
    struct Algo {
        /// Poids du Gyroscope (Rotation). Plus élevé car valeurs brutes faibles.
        static let gyroWeight: Double = 15.0
        
        /// Poids du Yaw (Changement de direction/Demi-tours).
        static let yawWeight: Double = 50.0
        
        /// Seuil minimum de changement de Yaw pour être pris en compte
        static let yawChangeThreshold: Double = 3.0
           
        // --- Calculs automatiques pour le CSV ---
        
        /// Nombre de lignes CSV correspondant à la fenêtre d'analyse (ex: 20s * 10Hz = 200 lignes)
        static let windowSizeInLines: Int = Int(Timing.analysisWindowSeconds * Sensors.frequency)
        
        /// Le "pas" de glissement (Stride). On analyse toutes les X secondes.
        /// Ici : on glisse d'un quart de la fenêtre (ex: 5 secondes)
        static let strideInLines: Int = windowSizeInLines / 4
    }
    
// ==========================================
// 🏆 CLASSEMENT & LOGIQUE DE SÉLECTION
// ==========================================
    struct Ranking {
        // --- Seuils de durée (en secondes) ---
        static let limitShort: TimeInterval = 600.0   // 10 minutes
        static let limitMedium: TimeInterval = 1500.0 // 25 minutes
        
        // --- Nombre de moments à garder par palier ---
        static let countShort: Int = 1  // Si < 10 min
        static let countMedium: Int = 3 // Si 10-25 min
        static let countLong: Int = 5   // Si > 25 min
        
        // --- Fonction dynamique ---
        // Cette fonction décide combien de moments on garde selon la durée totale
        static func getTargetCount(for duration: TimeInterval) -> Int {
            if duration < limitShort {
                return countShort
            } else if duration < limitMedium {
                return countMedium
            } else {
                return countLong
            }
        }
    
        /// Nombre maximum de candidats à pré-analyser (avant filtrage final).
        /// On prend une marge de sécurité (ex: le double du max possible) pour avoir du choix.
        static let initialCandidatesLimit: Int = countLong * 2
    }
    
    
    
// ==========================================
// ☁️ API & RÉSEAU
// ==========================================
    struct API {
        /// Temps max pour l'upload et l'analyse d'un morceau
        static let requestTimeout: TimeInterval = 25.0
    }
}
