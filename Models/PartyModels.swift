// ============================================================================
// 🎯 SECTION 1: MODÈLES DE DONNÉES
// ============================================================================

import Foundation

struct HighlightMoment: Identifiable, Hashable {
    let id = UUID()
    let timestamp: TimeInterval
    var song: RecognizedSong? = nil
    let peakScore: Double
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
}

