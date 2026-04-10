import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(StreamController.self) private var streamController
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VideoLog.timestampSec, order: .reverse) private var logs: [VideoLog]
        
        
    var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EYES ON GLASS")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .tracking(2)
                    
                    Text("TELEMETRY PROCESSING PIPELINE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // Status Indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(streamController.connectionStatus == "Active" ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: streamController.connectionStatus == "Active" ? .green : .red, radius: 4)
                    
                    Text(streamController.connectionStatus.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(streamController.connectionStatus == "Active" ? .green : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.3))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.1)), alignment: .bottom)
            
            // Main Content Area
            HStack(spacing: 24) {
                // Left Column - Controls & Stats
                VStack(spacing: 24) {
                    // Control Panel
                    ControlPanelView(streamController: streamController, modelContext: modelContext)
                    
                    // Hardware Metrics
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("HARDWARE ACQUISITION")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Spacer()
                            
                            Menu {
                                ForEach(["1m", "5m", "10m", "20m", "30m"], id: \.self) { timeframe in
                                    Button(action: {
                                        streamController.selectedTimeframe = timeframe
                                    }) {
                                        Text(timeframe)
                                        if streamController.selectedTimeframe == timeframe {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(streamController.selectedTimeframe)
                                        .font(.system(size: 11, design: .monospaced))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9))
                                }
                                .foregroundColor(.gray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(4)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        
                        MetricRow(label: "CPU USAGE", value: String(format: "%.1f%%", streamController.hardwareCPU))
                        MetricRow(label: "MEMORY (RES)", value: String(format: "%.0f MB", streamController.hardwareMemory))
                        MetricRow(label: "GPU USAGE", value: String(format: "%.1f%%", streamController.hardwareGPU))
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    
                    Spacer()
                }
                .frame(width: 320)
                
                // Right Column - Active Telemetry
                VStack(alignment: .leading, spacing: 16) {
                    Text("PIPELINE OBSERVABILITY (\(logs.count) EVENTS)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.4))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        if logs.isEmpty {
                            if streamController.connectionStatus == "Active" {
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.blue)
                                        .scaleEffect(1.5)
                                        .padding(.bottom, 16)
                                    
                                    Text("AWAITING NAL UNITS...")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                            } else {
                                Text("NO SIGNAL")
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.2))
                            }
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(logs) { log in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(log.issueType.uppercased())
                                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                    .foregroundColor(log.issueType == "ok" ? .green : .red)
                                                
                                                Text("PTS: \(String(format: "%.3f", log.timestampSec)) • Engine: \(log.analysisEngine ?? "unknown")")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.gray)
                                            }
                                            
                                            Spacer()
                                            
                                            if let score = log.issueScore {
                                                Text(String(format: "CONF: %.2f", score))
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.white.opacity(0.1))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        .padding(16)
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(8)
                                    }
                                }
                                .padding(16)
                            }
                        }
                    }
                }
            }
            .padding(24)
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

// Helper Component for Metrics
struct MetricRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

// Subview for Control Panel to isolate view re-evaluation
struct ControlPanelView: View {
    var streamController: StreamController
    var modelContext: ModelContext
    
    @State private var streamUri: String = "udp://239.0.0.1:1234"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CONNECTION URI")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            
            HStack {
                TextField("udp://...", text: $streamUri)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(12)
            .background(Color.black.opacity(0.4))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .disabled(streamController.connectionStatus == "Active")
            .opacity(streamController.connectionStatus == "Active" ? 0.5 : 1.0)
            
            Button(action: {
                Task {
                    if streamController.connectionStatus == "Active" {
                        await streamController.stopMonitoring()
                    } else {
                        await streamController.startMonitoring(uri: streamUri, context: modelContext)
                    }
                }
            }) {
                Text(streamController.connectionStatus == "Active" ? "DISCONNECT" : "INITIALIZE STREAM")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(streamController.connectionStatus == "Active" ? Color.red.opacity(0.2) : Color.blue.opacity(0.2))
                    .foregroundColor(streamController.connectionStatus == "Active" ? .red : .blue)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(streamController.connectionStatus == "Active" ? Color.red.opacity(0.5) : Color.blue.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
