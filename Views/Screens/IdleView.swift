// ============================================================================
// 🎨 MENU MAIN
// ============================================================================

import SwiftUI

struct IdleView: View {
    @Binding var history: [PartyReport]
    @Binding var savedFiles: [URL]
    var deleteHistoryAction: (IndexSet) -> Void
    var deleteFileAction: (IndexSet) -> Void
    
    @State private var selectedTab = 0
    
    var body: some View {
        VStack {
            Picker("Affichage", selection: $selectedTab) {
                Text("Journal").tag(0)
                Text("Fichiers ZIP").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle()).padding()
            
            if selectedTab == 0 {
                if history.isEmpty { EmptyState(icon: "music.note.list", text: "Aucune soirée enregistrée.") }
                else {
                    List {
                        ForEach(history) { report in
                            NavigationLink(destination: HistoryDetailView(report: report)) {
                                VStack(alignment: .leading) {
                                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.headline).foregroundColor(.white)
                                    Text("\(report.moments.count) moment(s) fort(s)").font(.caption).foregroundColor(.orange)
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }
                        .onDelete(perform: deleteHistoryAction)
                    }
                    .scrollContentBackground(.hidden)
                }
            } else {
                if savedFiles.isEmpty { EmptyState(icon: "doc.zipper", text: "Aucun fichier brut.") }
                else {
                    List {
                        ForEach(savedFiles, id: \.self) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(file.lastPathComponent).font(.caption).foregroundColor(.white)
                                    Text(getFileSize(url: file)).font(.caption2).foregroundColor(.gray)
                                }
                                Spacer()
                                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }
                        .onDelete(perform: deleteFileAction)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            Spacer()
        }
    }
    
    func getFileSize(url: URL) -> String {
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attr?[.size] as? Int64 ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct EmptyState: View {
    let icon: String; let text: String
    var body: some View { VStack { Spacer(); Image(systemName: icon).font(.system(size: 50)).foregroundColor(.gray); Text(text).foregroundColor(.gray).padding(.top); Spacer() } }
}

