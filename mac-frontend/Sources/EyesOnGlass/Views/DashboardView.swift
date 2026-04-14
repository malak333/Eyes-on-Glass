import SwiftData
import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(StreamController.self) private var streamController
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<VideoLog> { $0.isArchived == false }, sort: \VideoLog.timestampSec, order: .reverse) private var logs: [VideoLog]
    @State private var selectedLog: VideoLog?
    @State private var showAdvancedInspector: Bool = false
    var activeLogs: [VideoLog] {
        if let id = streamController.currentSessionIdentifier {
            return logs.filter { $0.sessionIdentifier == id }
        } else {
            return []
        }
    }
        
    var body: some View {
        NavigationSplitView {
            DashboardSidebar(streamController: streamController, modelContext: modelContext, logs: activeLogs)
        } detail: {
            Group {
                if activeLogs.isEmpty {
                    if streamController.connectionStatus == "Active" {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Awaiting NAL Units...")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ContentUnavailableView("No Signal", systemImage: "antenna.radiowaves.left.and.right", description: Text("Initialize stream to begin monitoring."))
                    }
                } else {
                    List(selection: $selectedLog) {
                        ForEach(activeLogs) { log in
                            LogEventRow(log: log)
                                .tag(log)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Eyes on Glass")
            .toolbar {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(streamController.connectionStatus == "Active" ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(streamController.connectionStatus)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showAdvancedInspector) {
                        Label("Advanced", systemImage: "sidebar.right")
                    }
                    .toggleStyle(.button)
                }

            }
        }
        .sheet(item: $selectedLog) { log in
            EventDetailView(log: log)
        }
        .inspector(isPresented: $showAdvancedInspector) {
            AdvancedInspectorView(streamController: streamController)
                .inspectorColumnWidth(min: 400, ideal: 500, max: 700)
        }
    }
}

struct LogEventRow: View {
    let log: VideoLog
    
    private var issueIconName: String {
        switch log.issueType {
        case "ok": return "checkmark.circle"
        case "stream_lost": return "wifi.exclamationmark"
        case "stream_restored": return "wifi"
        case "audio_lost": return "speaker.slash"
        case "audio_restored": return "speaker.wave.2"
        case "video_lost": return "video.slash"
        case "video_restored": return "video"
        case "cc_error": return "exclamationmark.triangle"
        default: return "waveform.path.ecg"
        }
    }
    
    private var issueTypeColor: Color {
        if let iat = log.iatMs, iat > 40.0 {
            return .red
        }
        switch log.issueType {
        case "ok", "stream_restored", "audio_restored", "video_restored": return .green
        case "stream_lost", "audio_lost", "video_lost": return .orange
        case "high_iat": return .red
        default: return .secondary
        }
    }
    
    private var issueTypeTextColor: Color {
        if let iat = log.iatMs, iat > 40.0 {
            return .red
        }
        switch log.issueType {
        case "ok", "stream_restored", "audio_restored", "video_restored": return .green
        case "stream_lost", "audio_lost", "video_lost": return .orange
        case "high_iat": return .red
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let path = log.thumbnailPath, !path.isEmpty {
                    let url = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents/EyesOnGlass/thumbnails")
                        .appendingPathComponent(path)
                    
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            Rectangle()
                                .fill(Color(NSColor.windowBackgroundColor))
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .overlay(AnomalyOverlayView(boundingBoxesJSON: log.boundingBoxes))
                        case .failure:
                            Rectangle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .overlay(Image(systemName: "exclamationmark.triangle").foregroundColor(.secondary))
                        @unknown default:
                            Rectangle()
                                .fill(Color(NSColor.windowBackgroundColor))
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color(NSColor.windowBackgroundColor))
                        .overlay(
                            Image(systemName: issueIconName)
                                .foregroundColor(issueTypeColor)
                                .font(.title2)
                        )
                }
            }
            .frame(width: 72, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(log.issueType.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.headline)
                    .foregroundColor(issueTypeTextColor)
                
                if let summary = log.issueSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(3)
                }
                
                Text(String(format: "PTS: %.3f • Engine: %@", log.timestampSec, log.analysisEngine ?? "unknown"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    
                Text("Time: \(log.createdAt.formatted())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let iat = log.iatMs {
                Text(String(format: "IAT: %.1f ms", iat))
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(iat > 40.0 ? Color.red.opacity(0.8) : Color.gray.opacity(0.2))
                    .foregroundColor(iat > 40.0 ? .white : .primary)
                    .cornerRadius(4)
            }
            
            if let score = log.issueScore {
                Text(String(format: "Conf: %.2f", score))
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EventDetailView: View {
    let log: VideoLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let path = log.thumbnailPath, !path.isEmpty {
                    let url = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents/EyesOnGlass/thumbnails")
                        .appendingPathComponent(path)
                    
                    Section {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(40)
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 400)
                                    .overlay(AnomalyOverlayView(boundingBoxesJSON: log.boundingBoxes))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            case .failure:
                                ContentUnavailableView("Image Load Failed", systemImage: "xmark.rectangle")
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
                
                Section("Event Metadata") {
                    LabeledContent("Issue Type", value: log.issueType.uppercased())
                    if let summary = log.issueSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Forensic Summary")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(summary)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                    if let score = log.issueScore {
                        LabeledContent("Confidence") {
                            Text(String(format: "%.2f", score)).monospacedDigit()
                        }
                    }
                    LabeledContent("PTS") {
                        Text(String(format: "%.3f", log.timestampSec)).monospacedDigit()
                    }
                    if let engine = log.analysisEngine {
                        LabeledContent("Engine", value: engine)
                    }
                    if let iat = log.iatMs {
                        LabeledContent("Inter-Arrival Time (IAT)") {
                            Text(String(format: "%.1f ms", iat))
                                .monospacedDigit()
                                .foregroundColor(iat > 40.0 ? .red : .primary)
                        }
                    }
                    LabeledContent("Time", value: log.createdAt.formatted())
                }
                
                Section("System Path") {
                    if !log.videoFilename.isEmpty {
                        LabeledContent("Filename", value: log.videoFilename)
                    }
                    if let nodeSource = log.nodeSource {
                        LabeledContent("Node Source", value: nodeSource)
                    }
                    if let nodeBackbone = log.nodeBackbone {
                        LabeledContent("Node Backbone", value: nodeBackbone)
                    }
                    if let nodeDest = log.nodeDest {
                        LabeledContent("Node Dest", value: nodeDest)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Event Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .frame(minWidth: 400, minHeight: 500)
        }
    }
}

struct DashboardSidebar: View {
    var streamController: StreamController
    var modelContext: ModelContext
    var logs: [VideoLog]
    
    var body: some View {
        List {
            ConnectionSectionView(streamController: streamController, modelContext: modelContext)
            
            if streamController.connectionStatus == "Active" || streamController.currentSessionIdentifier != nil {
                StreamStatsSectionView(streamController: streamController, logs: logs)
            }
            
            HardwareSectionView(streamController: streamController)
        }
        .navigationTitle("Telemetry Controls")
        .listStyle(.sidebar)
    }
}

struct StreamStatsSectionView: View {
    @Bindable var streamController: StreamController
    var logs: [VideoLog]
    
    var body: some View {
        Section("Stream Statistics") {
            LabeledContent("Duration", value: formatDuration(streamController.streamDuration))
                .monospacedDigit()
            LabeledContent("Packets Rx", value: "\(streamController.streamPackets)")
                .monospacedDigit()
            LabeledContent("Bitrate", value: String(format: "%.2f Mbps", streamController.streamBitrate))
                .monospacedDigit()
            LabeledContent("CC Errors (Stream)", value: "\(streamController.streamCCErrors)")
                .monospacedDigit()
            LabeledContent("CC Errors (Total)", value: "\(streamController.totalCCErrors)")
                .monospacedDigit()
            
            Button(action: {
                streamController.clearCCErrors()
            }) {
                Text("Clear CC Errors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            Button(action: {
                streamController.clearEvents()
            }) {
                Text("Clear Events")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            LabeledContent("Frames Analyzed", value: "\(streamController.streamFramesAnalyzed)")
                .monospacedDigit()
            
            let issuesCount = logs.filter { $0.issueType != "ok" }.count
            LabeledContent("Issues Extracted", value: "\(issuesCount)")
                .monospacedDigit()
            
            let score = logs.isEmpty ? 100.0 : ((Double(logs.count - issuesCount) / Double(logs.count)) * 100.0)
            LabeledContent("Health Score") {
                Text(String(format: "%.1f%%", score))
                    .foregroundColor(score > 90 ? .green : (score > 70 ? .orange : .red))
                    .bold()
                    .monospacedDigit()
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00:00"
    }
}

struct ConnectionSectionView: View {
    @Bindable var streamController: StreamController
    var modelContext: ModelContext
    @AppStorage("streamUri") private var streamUri: String = "udp://239.0.0.1:1234"
    @State private var localUri: String = ""
    @State private var vlmClient = NativeVLMClient.shared
    
    var body: some View {
        Section("Connection") {
            TextField("URI", text: $localUri)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(streamController.connectionStatus == "Active")
                .onAppear {
                    localUri = streamUri
                    if case .notLoaded = vlmClient.state {
                        Task { await vlmClient.prepareModel() }
                    }
                }
                .onChange(of: localUri) { oldValue, newValue in
                    streamUri = newValue
                }
            
            switch vlmClient.state {
            case .notLoaded:
                ProgressView() {
                    Text("Initializing...")
                        .font(.caption)
                }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Loading Model... \(Int(progress * 100))%")
                        .font(.caption)
                }
            case .loadingToMemory:
                ProgressView() {
                    Text("Loading to Unified Memory...")
                        .font(.caption)
                }
            case .error(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                Button(action: {
                    Task { await vlmClient.prepareModel() }
                }) {
                    Text("Retry Prepare Model")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .ready:
                Button(action: {
                    let uri = localUri
                    Task {
                        if streamController.connectionStatus == "Active" {
                            await streamController.stopMonitoring()
                        } else {
                            await streamController.startMonitoring(uri: uri, context: modelContext)
                        }
                    }
                }) {
                    Text(streamController.connectionStatus == "Active" ? "Disconnect" : "Initialize Stream")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(streamController.connectionStatus == "Active" ? .red : .blue)
            }
        }
    }
}

struct HardwareSectionView: View {
    @Bindable var streamController: StreamController
    @AppStorage("showHardwareGraphs") private var showHardwareGraphs: Bool = false
    
    var body: some View {
        Section("Hardware Acquisition") {
            Picker("Timeframe", selection: $streamController.selectedTimeframe) {
                ForEach(["1m", "5m", "10m", "20m", "30m"], id: \.self) { timeframe in
                    Text(timeframe).tag(timeframe)
                }
            }
            
            Toggle("Show Graphs", isOn: $showHardwareGraphs)
            
            LabeledContent("CPU Usage") {
                Text(String(format: "%.1f%%", streamController.hardwareCPU))
                    .monospacedDigit()
            }
            if showHardwareGraphs && !streamController.hardwareStatsHistory.isEmpty {
                Chart(streamController.hardwareStatsHistory, id: \.timestamp) { item in
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(item.timestamp))),
                        y: .value("CPU", item.cpu)
                    )
                    .foregroundStyle(.blue)
                }
                .frame(height: 80)
                .padding(.bottom, 8)
            }
            
            LabeledContent("Memory (RES)") {
                Text(String(format: "%.0f MB", streamController.hardwareMemory))
                    .monospacedDigit()
            }
            if showHardwareGraphs && !streamController.hardwareStatsHistory.isEmpty {
                Chart(streamController.hardwareStatsHistory, id: \.timestamp) { item in
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(item.timestamp))),
                        y: .value("Memory", item.memory)
                    )
                    .foregroundStyle(.purple)
                }
                .frame(height: 80)
                .padding(.bottom, 8)
            }
            
            LabeledContent("GPU Usage") {
                Text(String(format: "%.1f%%", streamController.hardwareGPU))
                    .monospacedDigit()
            }
            if showHardwareGraphs && !streamController.hardwareStatsHistory.isEmpty {
                Chart(streamController.hardwareStatsHistory, id: \.timestamp) { item in
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(item.timestamp))),
                        y: .value("GPU", item.gpu)
                    )
                    .foregroundStyle(.green)
                }
                .frame(height: 80)
                .padding(.bottom, 8)
            }
        }
    }
}
