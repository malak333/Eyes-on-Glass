import Foundation

struct StreamMetadata: Sendable {
    var videoPID: UInt16? = nil
    var audioPID: UInt16? = nil
    var videoResolution: CGSize? = nil
    var videoColor: String? = nil
    var videoGOPSize: Int? = nil
    var videoFrameRate: Double? = nil
    var audioSampleRate: Int? = nil
    var audioChannels: Int? = nil
    var audioCodec: String? = nil
    var audioBitrate: Double? = nil
    var audioLoudness: Double? = nil
    var audioTruePeak: Double? = nil
    var audioDialNorm: Int? = nil

    var tsID: UInt16? = nil
    var programID: UInt16? = nil
    var servicesCount: Int = 0
    var sdtChannel: String? = nil
    var sdtProvider: String? = nil

    var tsClock: String? = nil
    var pcrJitter: Double? = nil
    var pcrInterval: Double? = nil
}
