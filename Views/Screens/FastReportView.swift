// ============================================================================
// 🎨 MENU FAST REPORT
// ============================================================================

import SwiftUI

struct FastReportView: View {
    @Binding var moments: [HighlightMoment]; var onDone: () -> Void
    var body: some View { VStack { Text(moments.count == 1 ? "🏆 LE MOMENT D'OR" : "🔥 TOP 5 DE LA SOIRÉE").font(.title2).bold().foregroundColor(.white).padding(.top); if moments.isEmpty { Spacer(); Text("Aucune musique reconnue 😔").foregroundColor(.gray).padding(); Spacer() } else { List { ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in HStack(spacing: 15) { ZStack { Circle().fill(index == 0 ? Color.yellow : (index == 1 ? Color.gray : Color.orange)).frame(width: 30, height: 30); Text("\(index + 1)").font(.headline).foregroundColor(.black) }; VStack(alignment: .leading) { Text(m.song?.title ?? "Inconnu").font(.headline).foregroundColor(.white); Text(m.song?.artist ?? "").font(.caption).foregroundColor(.gray) }; Spacer(); Text(formatTime(m.timestamp)).font(.system(.caption, design: .monospaced)).padding(6).background(Color.white.opacity(0.1)).cornerRadius(8).foregroundColor(.white) }.listRowBackground(Color.white.opacity(0.1)).padding(.vertical, 5) } }.listStyle(.plain) }; Button(action: { onDone() }) { Text("Sauvegarder et continuer").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.blue).cornerRadius(15) }.padding() }.background(Color.black) }
    func formatTime(_ t: TimeInterval) -> String { let h = Int(t) / 3600; let m = Int(t) / 60 % 60; if h > 0 { return "\(h)h \(m)m" } else { return "\(m) min" } }
}
