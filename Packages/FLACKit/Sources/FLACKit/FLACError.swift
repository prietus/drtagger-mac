import Foundation

public enum FLACError: Error, Equatable {
    case notAFLACFile
    case truncated
    case invalidMetadataBlock(reason: String)
    case invalidVorbisComment(reason: String)
    case unsupportedStreamInfo
}
