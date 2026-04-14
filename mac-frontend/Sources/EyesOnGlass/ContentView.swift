import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var streamControllers: [StreamController] = [StreamController()]
    
    var body: some View {
        TabView {
            // First tab: the grid or tab of streams. We can just use standard tabs for now.
            ForEach(streamControllers) { controller in
                DashboardView()
                    .environment(controller)
                    .tabItem {
                        Label(controller.connectionStatus == "Active" ? (controller.streamIP) : "Stream \(streamControllers.firstIndex(of: controller)! + 1)", systemImage: "play.tv")
                    }
            }
            
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    streamControllers.append(StreamController())
                }) {
                    Label("Add Stream", systemImage: "plus")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
