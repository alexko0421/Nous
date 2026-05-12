import Foundation

enum AttachedFileKind: String, Codable {
    case image
    case pdf
    case textFile
    case link
}

struct AttachedFileContext: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let extractedText: String?
    let sourceText: String?
    let kind: AttachedFileKind
    let imageData: Data?
    let imageMimeType: String?
    let pdfData: Data?
    let linkURL: String?
    let linkTitle: String?
    let linkDescription: String?
    let linkThumbnailURL: String?

    init(
        id: UUID = UUID(),
        name: String,
        extractedText: String?,
        sourceText: String? = nil,
        kind: AttachedFileKind = .textFile,
        imageData: Data? = nil,
        imageMimeType: String? = nil,
        pdfData: Data? = nil,
        linkURL: String? = nil,
        linkTitle: String? = nil,
        linkDescription: String? = nil,
        linkThumbnailURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.extractedText = extractedText
        self.sourceText = sourceText
        self.kind = kind
        self.imageData = imageData
        self.imageMimeType = imageMimeType
        self.pdfData = pdfData
        self.linkURL = linkURL
        self.linkTitle = linkTitle
        self.linkDescription = linkDescription
        self.linkThumbnailURL = linkThumbnailURL
    }

    enum CodingKeys: String, CodingKey {
        case id, name, extractedText, sourceText, kind
        case imageData, imageMimeType, pdfData
        case linkURL, linkTitle, linkDescription, linkThumbnailURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.extractedText = try c.decodeIfPresent(String.self, forKey: .extractedText)
        self.sourceText = try c.decodeIfPresent(String.self, forKey: .sourceText)
        self.kind = try c.decodeIfPresent(AttachedFileKind.self, forKey: .kind) ?? .textFile
        self.imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        self.imageMimeType = try c.decodeIfPresent(String.self, forKey: .imageMimeType)
        self.pdfData = try c.decodeIfPresent(Data.self, forKey: .pdfData)
        self.linkURL = try c.decodeIfPresent(String.self, forKey: .linkURL)
        self.linkTitle = try c.decodeIfPresent(String.self, forKey: .linkTitle)
        self.linkDescription = try c.decodeIfPresent(String.self, forKey: .linkDescription)
        self.linkThumbnailURL = try c.decodeIfPresent(String.self, forKey: .linkThumbnailURL)
    }
}
