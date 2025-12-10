// ============================================================================
// 🎨 MENU HISTORY
// ============================================================================

import SwiftUI

struct HistoryDetailView: View {
    let report: PartyReport
    var body: some View { ZStack { Color.black.ignoresSafeArea(); List(report.moments) { m in VStack(alignment: .leading) { Text(m.title).font(.headline).foregroundColor(.white); Text(m.artist).font(.caption).foregroundColor(.gray); Text("À \(Int(m.timestamp / 60)) min \(Int(m.timestamp) % 60) s").font(.caption2).foregroundColor(.orange) }.listRowBackground(Color.white.opacity(0.1)) }.scrollContentBackground(.hidden) }.navigationTitle("Détails Soirée") }
}
