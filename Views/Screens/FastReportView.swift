// ============================================================================
// 🎨 MENU FAST REPORT
// ============================================================================

import SwiftUI

struct FastReportView: View {
    
    // 🔥 FIX : Reçoit le FastReport complet (non modifiable)
    let report: FastReport
    var onDone: () -> Void

    // Les moments sont extraits du rapport
    var moments: [SavedMoment]{
        return report.moments
    }
    
    // Propriété calculée pour le titre dynamique
    var dynamicTitle: String {
        let count = moments.count
        if count == 0 {
            return "❌ AUCUN MOMENT TROUVÉ"
        } else if count == 1 {
            return "🏆 LE MOMENT D'OR"
        } else if count <= 3 {
            return "🥉 PODIUM DE LA SOIRÉE"
        } else {
            return "🔥 TOP \(count) DE LA SOIRÉE"
        }
    }

    // Propriété calculée pour la couleur de la carte de santé
    var healthCardColor: Color {
        if report.audioHealthStatus.contains("Risque Élevé") { return Color.red.opacity(0.8) }
        if report.audioHealthStatus.contains("Festive") { return Color.orange.opacity(0.8) }
        return Color.green.opacity(0.8)
    }

    var body: some View {
        VStack(spacing: 0) {
            
            // TITRE DYNAMIQUE
            Text(dynamicTitle)
                .font(.title2)
                .bold()
                .foregroundColor(.white)
                .padding(.top, 20)
                .padding(.bottom, 10)

            if moments.isEmpty {
                Spacer()
                Text("Aucune musique reconnue ou moment significatif 😔")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                
                // 🔥 NOUVEAU : Message de Santé Auditive (Utilise le statut du rapport)
                Text(report.audioHealthStatus)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(healthCardColor)
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.bottom, 15)
                
                // LISTE DES MOMENTS
                List {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in
                        
                        VStack(alignment: .leading) {
                            // 1. Rang et Musique
                            HStack {
                                Text("#\(index + 1)")
                                    .fontWeight(.bold)
                                Text(m.title)
                                    .font(.headline)
                            }
                            
                            // 2. Artiste et Heure
                            HStack {
                                Text(m.artist)
                                Spacer()
                                Text(formatTime(m.timestamp))
                            }
                            .foregroundColor(.secondary)

                            // 3. Infos Techniques (BPM et dB)
                            HStack {
                                Text("Rythme: \(m.userBPM) BPM")
                                Text(" | ")
                                Text("Volume: \(Int(m.averagedB)) dB")
                            }
                            .font(.caption)
                            .foregroundColor(.gray)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            
            // BOUTON FINAL
            Button(action: { onDone() }) {
                Text("Sauvegarder et continuer")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(15)
            }
            .padding()
            
        }
        .background(Color.black.edgesIgnoringSafeArea(.all)) // Utilise le fond noir de ContentView
    }

    // Fonction d'aide pour le temps
    func formatTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = Int(t) / 60 % 60
        if h > 0 { return "\(h)h \(m)m" } else { return "\(m) min" }
    }
}
