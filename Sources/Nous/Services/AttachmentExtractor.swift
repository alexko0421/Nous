import Foundation
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum AttachmentExtractor {
    private static let maxTextFileBytes = 200_000
    fileprivate static let maxPreviewCharacters = 4_000

    private struct ExtractedFileText {
        let preview: String?
        let sourceText: String?
    }

    static func fileContexts(from urls: [URL]) -> [AttachedFileContext] {
        urls.map { url in
            let pathExtension = url.pathExtension.lowercased()
            let extracted = extractText(from: url)

            if pathExtension == "pdf" {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let pdfData = try? Data(contentsOf: url)
                return AttachedFileContext(
                    name: url.lastPathComponent,
                    extractedText: extracted.preview,
                    sourceText: extracted.sourceText,
                    kind: .pdf,
                    pdfData: pdfData
                )
            }

            if let type = UTType(filenameExtension: pathExtension), type.conforms(to: .image) {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let data = try? Data(contentsOf: url)
                let mime = type.preferredMIMEType ?? "image/png"
                return AttachedFileContext(
                    name: url.lastPathComponent,
                    extractedText: extracted.preview,
                    sourceText: extracted.sourceText,
                    kind: .image,
                    imageData: data,
                    imageMimeType: mime
                )
            }

            return AttachedFileContext(
                name: url.lastPathComponent,
                extractedText: extracted.preview,
                sourceText: extracted.sourceText,
                kind: .textFile
            )
        }
    }

    static func imageFileContexts(from urls: [URL]) -> [AttachedFileContext] {
        fileContexts(from: urls.filter(isImageFileURL))
    }

    static func photoContexts(from items: [PhotosPickerItem]) async -> [AttachedFileContext] {
        var contexts: [AttachedFileContext] = []

        for (index, item) in items.enumerated() {
            let utType = item.supportedContentTypes.first
            let fileExtension = utType?.preferredFilenameExtension ?? "jpeg"
            let mime = utType?.preferredMIMEType ?? "image/jpeg"
            let name = "Photo \(index + 1).\(fileExtension)"

            guard let data = try? await item.loadTransferable(type: Data.self) else {
                contexts.append(AttachedFileContext(name: name, extractedText: nil, kind: .image))
                continue
            }

            contexts.append(
                AttachedFileContext(
                    name: name,
                    extractedText: extractText(fromImageData: data),
                    kind: .image,
                    imageData: data,
                    imageMimeType: mime
                )
            )
        }

        return contexts
    }

    static func droppedImageContexts(from providers: [NSItemProvider]) async -> [AttachedFileContext] {
        var contexts: [AttachedFileContext] = []
        var imageDataIndex = 1

        for provider in providers {
            if let fileURL = await droppedFileURL(from: provider) {
                contexts.append(contentsOf: imageFileContexts(from: [fileURL]))
                continue
            }

            guard let data = await droppedImageData(from: provider) else { continue }
            let fileExtension = preferredImageFileExtension(from: provider)
            let mime = preferredImageMimeType(from: provider) ?? "image/png"
            contexts.append(
                AttachedFileContext(
                    name: "Dropped Image \(imageDataIndex).\(fileExtension)",
                    extractedText: extractText(fromImageData: data),
                    kind: .image,
                    imageData: data,
                    imageMimeType: mime
                )
            )
            imageDataIndex += 1
        }

        return contexts
    }

    /// Generalized drop handler: any file URL (image, PDF, text) plus inline image data.
    /// PDFs and text files come through here too, not just images.
    static func droppedAttachmentContexts(from providers: [NSItemProvider]) async -> [AttachedFileContext] {
        var contexts: [AttachedFileContext] = []
        var imageDataIndex = 1

        for provider in providers {
            if let fileURL = await droppedFileURL(from: provider) {
                contexts.append(contentsOf: fileContexts(from: [fileURL]))
                continue
            }

            if let representedFileContexts = await droppedRepresentedFileContexts(from: provider) {
                contexts.append(contentsOf: representedFileContexts)
                continue
            }

            guard let data = await droppedImageData(from: provider) else { continue }
            let fileExtension = preferredImageFileExtension(from: provider)
            let mime = preferredImageMimeType(from: provider) ?? "image/png"
            contexts.append(
                AttachedFileContext(
                    name: "Dropped Image \(imageDataIndex).\(fileExtension)",
                    extractedText: extractText(fromImageData: data),
                    kind: .image,
                    imageData: data,
                    imageMimeType: mime
                )
            )
            imageDataIndex += 1
        }

        return contexts
    }

    private static func extractText(from url: URL) -> ExtractedFileText {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let pathExtension = url.pathExtension.lowercased()

        if pathExtension == "pdf" {
            return documentText(PDFDocument(url: url)?.string)
        }

        if let type = UTType(filenameExtension: pathExtension),
           type.conforms(to: .image),
           let data = try? Data(contentsOf: url) {
            return ExtractedFileText(
                preview: extractText(fromImageData: data),
                sourceText: nil
            )
        }

        guard let data = try? Data(contentsOf: url),
              data.count <= maxTextFileBytes else {
            return ExtractedFileText(preview: nil, sourceText: nil)
        }

        for encoding in [String.Encoding.utf8, .unicode, .utf16, .ascii] {
            if let text = String(data: data, encoding: encoding) {
                return documentText(text)
            }
        }

        return ExtractedFileText(preview: nil, sourceText: nil)
    }

    private static func documentText(_ text: String?) -> ExtractedFileText {
        let sourceText = text?.sourceDocumentText
        return ExtractedFileText(
            preview: sourceText?.attachmentPreview,
            sourceText: sourceText
        )
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func extractText(fromImageData data: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: data)
        try? handler.perform([request])

        let text = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        return text?.attachmentPreview
    }

    private static func droppedFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: fileURL(fromDroppedItem: item))
            }
        }
    }

    private static func fileURL(fromDroppedItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    private static func droppedRepresentedFileContexts(from provider: NSItemProvider) async -> [AttachedFileContext]? {
        for identifier in representedFileTypeIdentifiers(from: provider) {
            if let contexts = await droppedInPlaceFileContexts(from: provider, typeIdentifier: identifier) {
                return contexts
            }

            if let contexts = await droppedTemporaryFileContexts(from: provider, typeIdentifier: identifier) {
                return contexts
            }
        }

        return nil
    }

    private static func representedFileTypeIdentifiers(from provider: NSItemProvider) -> [String] {
        var identifiers = provider.registeredTypeIdentifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .item)
        }

        for fallback in [UTType.item.identifier, UTType.data.identifier] where !identifiers.contains(fallback) {
            identifiers.append(fallback)
        }

        return identifiers
    }

    private static func droppedInPlaceFileContexts(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> [AttachedFileContext]? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: fileContexts(from: [url]))
            }
        }
    }

    private static func droppedTemporaryFileContexts(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> [AttachedFileContext]? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: fileContexts(from: [url]))
            }
        }
    }

    private static func droppedImageData(from provider: NSItemProvider) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func preferredImageFileExtension(from provider: NSItemProvider) -> String {
        provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first { $0.conforms(to: .image) }?
            .preferredFilenameExtension ?? "png"
    }

    private static func preferredImageMimeType(from provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first { $0.conforms(to: .image) }?
            .preferredMIMEType
    }
}

enum AttachmentDropSupport {
    /// Explicit importer types keep NSOpenPanel from disabling selectable PDFs.
    static let fileImporterContentTypes: [UTType] = [
        .pdf,
        .text,
        .plainText,
        .utf8PlainText,
        .rtf,
        .image,
        .data
    ]

    /// Source reader imports should feel like opening a readable document, not adding photos.
    static let sourceReaderContentTypes: [UTType] = [
        .pdf,
        .text,
        .plainText,
        .utf8PlainText,
        .rtf,
        .commaSeparatedText,
        .json
    ] + [
        UTType(filenameExtension: "md"),
        UTType(filenameExtension: "markdown")
    ].compactMap { $0 }

    /// Composer image-only drop targets (used where only images make sense).
    static let acceptedTypeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.image.identifier
    ]

    /// Whole-chat-surface drop targets — any file (image, PDF, text) + inline image data.
    static let allFileTypeIdentifiers = [
        UTType.item.identifier,
        UTType.fileURL.identifier,
        UTType.image.identifier,
        UTType.pdf.identifier,
        UTType.data.identifier
    ]
}

enum AttachmentLimitPolicy {
    static let maxImageAttachments = 5

    static func limitingImageAttachments(_ attachments: [AttachedFileContext]) -> [AttachedFileContext] {
        applyingImageLimit(to: [], appending: attachments)
    }

    static func applyingImageLimit(
        to existingAttachments: [AttachedFileContext],
        appending newAttachments: [AttachedFileContext]
    ) -> [AttachedFileContext] {
        var imageCount = existingAttachments.filter(isImageAttachment).count
        var acceptedAttachments = existingAttachments

        for attachment in newAttachments {
            guard isImageAttachment(attachment) else {
                acceptedAttachments.append(attachment)
                continue
            }

            guard imageCount < maxImageAttachments else { continue }
            acceptedAttachments.append(attachment)
            imageCount += 1
        }

        return acceptedAttachments
    }

    static func isDuplicateNonImageAttachment(
        _ attachment: AttachedFileContext,
        of existingAttachment: AttachedFileContext
    ) -> Bool {
        guard !isImageAttachment(attachment),
              !isImageAttachment(existingAttachment) else {
            return false
        }
        return attachment.name == existingAttachment.name &&
            attachment.extractedText == existingAttachment.extractedText &&
            attachment.sourceText == existingAttachment.sourceText
    }

    static func remainingImageSlots(in attachments: [AttachedFileContext]) -> Int {
        max(0, maxImageAttachments - attachments.filter(isImageAttachment).count)
    }

    static func isImageAttachment(_ attachment: AttachedFileContext) -> Bool {
        let pathExtension = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

private extension String {
    var sourceDocumentText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var attachmentPreview: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(AttachmentExtractor.maxPreviewCharacters))
    }
}
