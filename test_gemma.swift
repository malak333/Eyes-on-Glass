import Foundation

let jsonStr = """
        {
          "audio_seq_length": 750,
          "image_processor": {
            "do_convert_rgb": true,
            "do_normalize": false,
            "do_rescale": true,
            "do_resize": true,
            "image_mean": [0.0, 0.0, 0.0],
            "image_processor_type": "Gemma4ImageProcessor",
            "image_seq_length": 280,
            "image_std": [1.0, 1.0, 1.0],
            "max_soft_tokens": 280,
            "patch_size": 16,
            "pooling_kernel_size": 3,
            "resample": 3,
            "rescale_factor": 0.00392156862745098,
            "size": {"height": 224, "width": 224}
          },
          "image_seq_length": 280,
          "processor_class": "Gemma4Processor",
          "feature_extractor": {
             "feature_extractor_type": "Gemma4AudioFeatureExtractor"
          },
          "audio_ms_per_token": 40
        }
"""

struct ImageSize: Codable {
    let height: Int
    let width: Int
}
        
struct Gemma4ProcessorConfiguration: Codable {
    public let processorClass: String
    public let doNormalize: Bool
    public let imageMean: [CGFloat]
    public let imageStd: [CGFloat]
    public let imageSeqLength: Int
    public let size: ImageSize?

    public let imageTokenId: Int
    public let boiTokenId: Int
    public let eoiTokenId: Int?

    enum CodingKeys: String, CodingKey {
        case processorClass = "processor_class"
        case doNormalize = "do_normalize"
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case imageSeqLength = "image_seq_length"
        case size
        case imageTokenId = "image_token_id"
        case boiTokenId = "boi_token_id"
        case eoiTokenId = "eoi_token_id"
    }

    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processorClass = try c.decode(String.self, forKey: CodingKeys.processorClass)
        doNormalize = try c.decodeIfPresent(Bool.self, forKey: CodingKeys.doNormalize) ?? false
        imageMean =
            try c.decodeIfPresent([CGFloat].self, forKey: CodingKeys.imageMean) ?? [0.5, 0.5, 0.5]
        imageStd =
            try c.decodeIfPresent([CGFloat].self, forKey: CodingKeys.imageStd) ?? [0.5, 0.5, 0.5]
        imageSeqLength = try c.decodeIfPresent(Int.self, forKey: CodingKeys.imageSeqLength) ?? 280
        size = try c.decodeIfPresent(ImageSize.self, forKey: CodingKeys.size)
        imageTokenId = try c.decodeIfPresent(Int.self, forKey: CodingKeys.imageTokenId) ?? 258_880
        boiTokenId = try c.decodeIfPresent(Int.self, forKey: CodingKeys.boiTokenId) ?? 255_999
        eoiTokenId = try c.decodeIfPresent(Int.self, forKey: CodingKeys.eoiTokenId) ?? 258_882
    }
}
let data = jsonStr.data(using: .utf8)!
do {
    let config = try JSONDecoder().decode(Gemma4ProcessorConfiguration.self, from: data)
    print("Success: \(config.processorClass)")
} catch {
    print("Error: \(error)")
}
