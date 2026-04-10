import Foundation

let path = "/Users/michaelnobile/Antigravity/Eyes-on-Glass/mac-frontend/Sources/EyesOnGlass/Services/H264Decoder.swift"
var content = try! String(contentsOfFile: path)

// Add properties
let properties = """
    private let stateLock = NSLock()
    private var needsSessionDrop = false
    private var isWaitingForSync = false
    
    // Video info properties
    private var _lastGOPSize: Int = 0
    private var _currentGOPCount: Int = 0
    public var gopSize: Int { _lastGOPSize == 0 ? _currentGOPCount : _lastGOPSize }
    
    private var lastEmittedPTS: Int64? = nil
    private var currentFrameRate: Double = 0.0
    public var frameRate: Double { currentFrameRate }
    
    public var videoColor: String? {
        guard let format = formatDesc else { return nil }
        if let extensions = CMFormatDescriptionGetExtensions(format) as Dictionary? {
            if let colorPrimaries = extensions[kCVImageBufferColorPrimariesKey] as? String {
                if colorPrimaries.contains("709") { return "BT.709" }
                if colorPrimaries.contains("2020") { return "BT.2020" }
                if colorPrimaries.contains("601") { return "BT.601" }
                return colorPrimaries
            }
        }
        return nil
    }
"""
content = content.replacingOccurrences(of: "    private let stateLock = NSLock()\n    private var needsSessionDrop = false\n    private var isWaitingForSync = false", with: properties)

let countReplace = """
        if isCurrentFrameSync {
            createDecompressionSession()
            isWaitingForSync = false
            
            if _currentGOPCount > 0 {
                _lastGOPSize = _currentGOPCount
            }
            _currentGOPCount = 0
        }
"""
content = content.replacingOccurrences(of: """
        if decompressionSession == nil && formatDesc != nil {
            if isCurrentFrameSync {
                createDecompressionSession()
                isWaitingForSync = false
            } else {
""", with: """
        if decompressionSession == nil && formatDesc != nil {
            if isCurrentFrameSync {
                createDecompressionSession()
                isWaitingForSync = false
            } else {
""")

// actually, let's just insert GOP logic inside decodeAccumulatedFrame()
let gopReplace = """
        if isCurrentFrameSync {
            if _currentGOPCount > 0 {
                _lastGOPSize = _currentGOPCount
            }
            _currentGOPCount = 0
        }
        _currentGOPCount += 1
        
        if decompressionSession == nil && formatDesc != nil {
"""
content = content.replacingOccurrences(of: "        if decompressionSession == nil && formatDesc != nil {", with: gopReplace)

let resetReplace = """
        currentFrameDTS = nil
        isCurrentFrameSync = false
        isWaitingForSync = true
        
        _lastGOPSize = 0
        _currentGOPCount = 0
        lastEmittedPTS = nil
        currentFrameRate = 0.0
"""
content = content.replacingOccurrences(of: """
        currentFrameDTS = nil
        isCurrentFrameSync = false
        isWaitingForSync = true
""", with: resetReplace)

try! content.write(toFile: path, atomically: true, encoding: .utf8)
