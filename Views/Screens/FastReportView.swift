// ============================================================================
// 🎨 MENU FAST REPORT
// ============================================================================

import SwiftUI

struct FastReportView: View {
    let report: PartyReport
    var onDone: () -> Void
    
    // Simplification pour l'accès aux moments (qui sont des SavedMoment)
    var moments: [SavedMoment] { report.moments }

    // Calcul du titre dynamique
    var titleText: String {
        switch moments.count {
        case 0: return "😔 AUCUN MOMENT FORT TROUVÉ"
        case 1: return "🏆 LE MOMENT D'OR"
        case 2, 3: return "🥉 TOP \(moments.count) DE LA SOIRÉE"
        case 4, 5: return "🔥 TOP 5 DE LA SOIRÉE"
        default: return "✨ RAPPORT D'ANALYSE"
        }
    }
    
    // Détermine la couleur pour le statut de risque
    var statusColor: Color {
        if report.audioHealthStatus.contains("Risque Élevé") {
            return .red
        } else if report.audioHealthStatus.contains("Festive") {
            return .yellow
        } else {
            return .green
        }
    }
    
    var body: some View {
        VStack {
            Text(titleText)
                .font(.title2).bold().foregroundColor(.white).padding(.top)
            
            // Affichage du statut de santé auditive
            Text(report.audioHealthStatus)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(statusColor)
                .padding(.horizontal)
                .padding(.bottom, 15)

            if moments.isEmpty {
                Spacer()
                Text("Aucune musique reconnue 😔").foregroundColor(.gray).padding()
                Spacer()
            } else {
                List {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 15) {
                                ZStack {
                                    Circle()
                                        .fill(index == 0 ? Color.yellow : (index == 1 ? Color.gray : Color.orange))
                                        .frame(width: 30, height: 30)
                                    Text("\(index + 1)").font(.headline).foregroundColor(.black)
                                }
                                
                                VStack(alignment: .leading) {
                                    // Affichage du statut de reconnaissance
                                    Text(m.title)
                                        .font(.headline)
                                        .foregroundColor(m.title == "Inconnu" ? .red : .white)

                                    Text(m.artist.isEmpty ? "Mouvement pur ou artiste inconnu" : m.artist)
                                        .font(.caption).foregroundColor(.gray)
                                }
                                
                                Spacer()
                                
                                // L'heure du passage
                                Text(formatTime(m.timestamp))
                                    .font(.system(.caption, design: .monospaced)).padding(6).background(Color.white.opacity(0.1)).cornerRadius(8).foregroundColor(.white)
                            }
                            
                            // Ligne des données techniques (BPM et dB)
                            HStack {
                                Text("Rythme: \(m.userBPM) BPM")
                                Text("|")
                                // m.averagedB est un Double, on l'affiche en Int pour la lisibilité
                                Text("Volume: \(Int(m.averagedB)) dB")
                            }
                            .font(.caption2)
                            .foregroundColor(.pink)
                            .padding(.leading, 45) // Alignement
                            
                        }
                        .listRowBackground(Color.white.opacity(0.1)).padding(.vertical, 5)
                    }
                }
                .listStyle(.plain)
            }
            
            Button(action: { onDone() }) {
                Text("Sauvegarder et continuer").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.blue).cornerRadius(15)
            }.padding()
        }
        .background(Color.black)
    }
    
    func formatTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600; let m = Int(t) / 60 % 60;
        if h > 0 { return "\(h)h \(m)m" } else { return "\(m) min" }
    }
}
