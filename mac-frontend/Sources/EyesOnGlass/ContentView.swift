import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var streamController = StreamController.shared
    
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge")
                }
            
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
        }
        .environment(streamController)
        .frame(minWidth: 900, minHeight: 600)
    }
}
