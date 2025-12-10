// ============================================================================
// 🎨 MENU ANALYZING
// ============================================================================

import SwiftUI

struct AnalyzingView: View {
    let progress: Double
    var body: some View { VStack(spacing: 20) { Spacer(); ProgressView(value: progress).progressViewStyle(LinearProgressViewStyle(tint: Color.pink)).padding(); Text("Analyse Intelligente en cours...").foregroundColor(.white); Text("\(Int(progress * 100))%").font(.caption).foregroundColor(.gray); Spacer() } }
}
