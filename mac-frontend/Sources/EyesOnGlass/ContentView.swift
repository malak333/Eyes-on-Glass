import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var streamController = StreamController.shared
    
    var body: some View {
        DashboardView()
            .environment(streamController)
            .edgesIgnoringSafeArea(.all)
            .frame(minWidth: 900, minHeight: 600)
    }
}
