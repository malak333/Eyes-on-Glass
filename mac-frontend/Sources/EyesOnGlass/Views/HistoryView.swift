import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VideoLog.createdAt, order: .reverse) private var logs: [VideoLog]
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HISTORY")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .tracking(2)
                    
                    Text("PRIOR RUNS AND OBSERVABILITY LOGS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.1)), alignment: .bottom)
            
            // Main Content Area
            if logs.isEmpty {
                VStack {
                    Spacer()
                    Text("NO HISTORY FOUND")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.4))
                    Spacer()
                }
            } else {
                Table(logs) {
                    TableColumn("Date") { log in
                        Text(log.createdAt.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    TableColumn("Type") { log in
                        Text(log.issueType.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(log.issueType == "ok" ? .green : .red)
                    }
                    TableColumn("Engine") { log in
                        Text(log.analysisEngine ?? "N/A")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    TableColumn("PTS") { log in
                        Text(String(format: "%.3f", log.timestampSec))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    TableColumn("Confidence") { log in
                        if let score = log.issueScore {
                            Text(String(format: "%.2f", score))
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            Text("-")
                        }
                    }
                    TableColumn("Source URI") { log in
                        Text(log.videoFilename)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(
            Color.black
                .overlay(
                    LinearGradient(colors: [Color.blue.opacity(0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .preferredColorScheme(.dark)
    }
}
