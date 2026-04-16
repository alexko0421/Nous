import Foundation
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum AttachmentExtractor {
    private static let maxTextFileBytes = 200_000
    fileprivate static let maxPreviewCharacters = 4_000

    static func fileContexts(from urls: [URL]) -> [AttachedFileContext] {
        urls.map { url in
            AttachedFileContext(
                name: url.lastPathComponent,
                extractedText: extractText(from: url)
            )
        }
    }

    static func photoContexts(from items: [PhotosPickerItem]) async -> [AttachedFileContext] {
        var contexts: [AttachedFileContext] = []

        for (index, item) in items.enumerated() {
            let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpeg"
            let name = "Photo \(index + 1).\(fileExtension)"

            guard let data = try? await item.loadTransferable(type: Data.self) else {
                contexts.append(AttachedFileContext(name: name, extractedText: nil))
                continue
            }

            contexts.append(
                AttachedFileContext(
                    name: name,
                    extractedText: extractText(fromImageData: data)
                )
            )
        }

        return contexts
    }

    private static func extractText(from url: URL) -> String? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let pathExtension = url.pathExtension.lowercased()

        if pathExtension == "pdf" {
            return PDFDocument(url: url)?.string?.attachmentPreview
        }

        if let type = UTType(filenameExtension: pathExtension),
           type.conforms(to: .image),
           let data = try? Data(contentsOf: url) {
            return extractText(fromImageData: data)
        }

        guard let data = try? Data(contentsOf: url),
              data.count <= maxTextFileBytes else {
            return nil
        }

        for encoding in [String.Encoding.utf8, .unicode, .utf16, .ascii] {
            if let text = String(data: data, encoding: encoding),
               let preview = text.attachmentPreview {
                return preview
            }
        }

        return nil
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
}

private extension String {
    var attachmentPreview: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(AttachmentExtractor.maxPreviewCharacters))
    }
}
