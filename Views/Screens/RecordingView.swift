// ============================================================================
// 🎨 MENU RECORDING
// ============================================================================

import SwiftUI

struct RecordingView: View {
    @Binding var elapsedTimeString: String; @State private var pulse = false
    var body: some View { VStack(spacing: 30) { Spacer(); ZStack { Circle().stroke(Color.red.opacity(0.5), lineWidth: 2).frame(width: 200, height: 200).scaleEffect(pulse ? 1.2 : 1.0).opacity(pulse ? 0 : 1).onAppear { withAnimation(Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true } }; Text(elapsedTimeString).font(.system(size: 50, weight: .bold, design: .monospaced)).foregroundColor(.white) }; Text("Capture de l'ambiance...").foregroundColor(.gray); Spacer() } }
}
