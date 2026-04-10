import SwiftData
import SwiftUI

struct RunGroup: Identifiable {
    var id: String { session }
    let session: String
    let startTime: Date
    let logs: [VideoLog]
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<VideoLog> { $0.isArchived == true }, sort: \VideoLog.createdAt, order: .reverse) private var archivedLogs: [VideoLog]
    @Query(sort: \VideoLog.createdAt, order: .reverse) private var logs: [VideoLog]
    @State private var selectedLogId: VideoLog.ID?
    @State private var selectedLog: VideoLog?
    
    // We will use a dictionary to keep track of the expanded state of each group.
    @State private var expandedStates: [String: Bool] = [:]
    
    var groupedLogs: [RunGroup] {
        let grouped = Dictionary(grouping: archivedLogs, by: { $0.sessionIdentifier ?? "Unknown Run" })
        
        var result: [RunGroup] = []
        for (session, logs) in grouped {
            let startTime = logs.first(where: { $0.sessionStartTime != nil })?.sessionStartTime ?? logs.first?.createdAt ?? Date()
            let sortedLogs = logs.sorted { $0.timestampSec > $1.timestampSec }
            result.append(RunGroup(session: session, startTime: startTime, logs: sortedLogs))
        }
        return result.sorted { $0.startTime > $1.startTime }
    }
    
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
            if archivedLogs.isEmpty {
                VStack {
                    Spacer()
                    Text("NO HISTORY FOUND")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.4))
                    Spacer()
                }
            } else {
                List {
                    ForEach(groupedLogs) { group in
                        Section(header: Text("Run: \(group.startTime.formatted(date: .abbreviated, time: .standard)) - \(group.session)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)) {
                            
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedStates[group.id] ?? false },
                                    set: { expandedStates[group.id] = $0 }
                                )
                            ) {
                                // Header row for columns
                                HStack {
                                    Text("Time").frame(width: 100, alignment: .leading)
                                    Text("Type").frame(width: 80, alignment: .leading)
                                    Text("Engine").frame(width: 120, alignment: .leading)
                                    Text("PTS").frame(width: 80, alignment: .leading)
                                    Text("Confidence").frame(width: 80, alignment: .leading)
                                    Text("Source URI").frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                                .padding(.bottom, 4)
                                
                                ForEach(group.logs) { log in
                                    HStack {
                                        Text(log.createdAt.formatted(date: .omitted, time: .standard))
                                            .frame(width: 100, alignment: .leading)
                                        Text(log.issueType.uppercased())
                                            .foregroundColor(log.issueType == "ok" ? .green : .red)
                                            .frame(width: 80, alignment: .leading)
                                        // Extracted to avoid compiler type checking timeout
                                        LogEngineView(engine: log.analysisEngine)
                                        Text(String(format: "%.3f", log.timestampSec))
                                            .frame(width: 80, alignment: .leading)
                                        LogScoreView(score: log.issueScore)
                                        Text(log.videoFilename)
                                            .foregroundColor(.gray)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .onHover { isHovered in
                                        if isHovered {
                                            NSCursor.pointingHand.push()
                                        } else {
                                            NSCursor.pop()
                                        }
                                    }
                                    .onTapGesture {
                                        selectedLog = log
                                    }
                                }
                            } label: {
                                Text("Details")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $selectedLog) { log in
            EventDetailView(log: log)
                .onDisappear {
                    selectedLogId = nil
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

// Subviews to keep compiler happy
struct LogEngineView: View {
    let engine: String?
    var body: some View {
        Text(engine ?? "N/A")
            .frame(width: 120, alignment: .leading)
    }
}

struct LogScoreView: View {
    let score: Double?
    var body: some View {
        if let s = score {
            Text(String(format: "%.2f", s))
                .frame(width: 80, alignment: .leading)
        } else {
            Text("-")
                .frame(width: 80, alignment: .leading)
        }
    }
}
