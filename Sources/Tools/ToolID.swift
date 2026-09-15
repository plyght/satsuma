import Foundation

enum ToolArity {
    case single
    case multiple
    case any
}

enum ToolID: String, CaseIterable, Identifiable {
    case compress
    case editMetadata
    case editImage
    case frameImage
    case cropImage
    case redactImage
    case resizeImage
    case rotateImage
    case createPDF
    case createCollage
    case trimVideo
    case cropVideo
    case changeVideoSpeed
    case joinVideos
    case videoSnapshots
    case splitVideo
    case redactVideo
    case normalizeAudio
    case audioToVideo
    case trimAudio
    case audioChannels
    case redactAudio
    case mergePDF
    case organizePDF
    case splitPDF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .editMetadata: return "Edit metadata"
        case .editImage: return "Edit photo"
        case .frameImage: return "Add a background"
        case .cropImage: return "Crop image"
        case .redactImage: return "Redact photo"
        case .resizeImage: return "Resize images"
        case .rotateImage: return "Rotate & flip"
        case .createPDF: return "Create a PDF"
        case .createCollage: return "Create a collage"
        case .trimVideo: return "Trim video"
        case .cropVideo: return "Crop video"
        case .changeVideoSpeed: return "Change video speed"
        case .joinVideos: return "Join videos"
        case .videoSnapshots: return "Save video frames"
        case .splitVideo: return "Split video"
        case .redactVideo: return "Redact video"
        case .normalizeAudio: return "Normalize volume"
        case .audioToVideo: return "Audio visualizer"
        case .trimAudio: return "Trim audio"
        case .audioChannels: return "Audio channels"
        case .redactAudio: return "Bleep audio"
        case .mergePDF: return "Merge PDFs"
        case .organizePDF: return "Organize PDF pages"
        case .splitPDF: return "Split PDF"
        }
    }

    var radialLabel: String {
        switch self {
        case .compress: return "COMPRESS"
        case .editMetadata: return "METADATA"
        case .editImage: return "EDIT"
        case .frameImage: return "ADD BG"
        case .cropImage, .cropVideo: return "CROP"
        case .redactImage, .redactVideo: return "REDACT"
        case .resizeImage: return "RESIZE"
        case .rotateImage: return "ROTATE"
        case .createPDF: return "PDF"
        case .createCollage: return "COLLAGE"
        case .trimVideo, .trimAudio: return "TRIM"
        case .changeVideoSpeed: return "SPEED"
        case .joinVideos: return "JOIN"
        case .videoSnapshots: return "FRAMES"
        case .splitVideo, .splitPDF: return "SPLIT"
        case .normalizeAudio: return "NORMALIZE"
        case .audioToVideo: return "VISUALIZE"
        case .audioChannels: return "CHANNELS"
        case .redactAudio: return "BLEEP"
        case .mergePDF: return "MERGE"
        case .organizePDF: return "ORGANIZE"
        }
    }

    var icon: Reicon {
        switch self {
        case .compress: return .compress
        case .editMetadata: return .tagCross
        case .editImage: return .sliders
        case .frameImage: return .galleryAdd
        case .cropImage: return .crop
        case .cropVideo: return .crop2
        case .redactImage: return .eyeOff
        case .redactVideo: return .videoOff
        case .resizeImage: return .maximize
        case .rotateImage: return .arrowRotate
        case .createPDF: return .filePdf
        case .createCollage: return .layout
        case .trimVideo: return .scissors
        case .trimAudio: return .scissorsSquare
        case .changeVideoSpeed: return .playbackSpeed
        case .joinVideos: return .link
        case .videoSnapshots: return .camera
        case .splitVideo: return .videoCut
        case .splitPDF: return .files
        case .normalizeAudio: return .soundwave
        case .audioToVideo: return .musicPlay
        case .audioChannels: return .headphones
        case .redactAudio: return .mute
        case .mergePDF: return .docs
        case .organizePDF: return .reorder
        }
    }

    var categories: Set<FormatCategory> {
        switch self {
        case .compress, .editMetadata:
            return [.image, .video, .audio, .document]
        case .editImage, .frameImage, .cropImage, .redactImage, .resizeImage, .rotateImage, .createPDF, .createCollage:
            return [.image]
        case .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .redactVideo:
            return [.video]
        case .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio:
            return [.audio]
        case .mergePDF, .organizePDF, .splitPDF:
            return [.document]
        }
    }

    var arity: ToolArity {
        switch self {
        case .compress, .editMetadata, .resizeImage, .rotateImage, .createPDF: return .any
        case .createCollage, .joinVideos, .mergePDF: return .multiple
        default: return .single
        }
    }

    func applies(to formats: [FileFormat]) -> Bool {
        guard !formats.isEmpty else { return false }
        let categories = Set(formats.map(\.category))
        guard categories.count == 1, let category = categories.first, self.categories.contains(category) else { return false }
        if category == .document {
            switch self {
            case .mergePDF, .organizePDF, .splitPDF, .editMetadata, .compress:
                guard formats.allSatisfy({ $0 == .pdf }) else { return false }
            default:
                return false
            }
        }
        if category == .video, formats.contains(.gif), self != .compress, self != .editMetadata { return false }
        switch arity {
        case .single: return formats.count == 1
        case .multiple: return formats.count >= 2
        case .any: return true
        }
    }

    static func available(for formats: [FileFormat]) -> [ToolID] {
        allCases.filter { $0.applies(to: formats) }
    }

    static var total: Int { allCases.count }
}
