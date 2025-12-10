// ============================================================================
// 🎯 SECTION 1: MODÈLES DE DONNÉES
// ============================================================================

import Foundation

struct HighlightMoment: Identifiable, Hashable {
    let id = UUID()
    let timestamp: TimeInterval
    var song: RecognizedSong? = nil
    let peakScore: Double

    var userBPM: Int = 0
    var musicBPM: Int = 0
    var averagedB: Double = -160.0
    
}

struct RecognizedSong: Hashable {
    let title: String
    let artist: String
}

struct PartyReport: Identifiable, Codable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
    let moments: [SavedMoment]
}

struct SavedMoment: Codable, Identifiable {
    var id = UUID()
    let timestamp: TimeInterval
    let title: String
    let artist: String
    let userBPM: Int
    let musicBPM: Int
    let averagedB: Double // Double pour la précision des décibels
}

