import Foundation

enum LinkUnfurlService {
    private static let fetchTimeout: TimeInterval = 4.0
    private static let maxBytes = 200_000

    static func unfurl(_ url: URL) async -> AttachedFileContext {
        guard let metadata = await fetchMetadata(url) else {
            return nakedLinkAttachment(for: url)
        }
        return AttachedFileContext(
            name: metadata.title ?? url.host ?? url.absoluteString,
            extractedText: nil,
            kind: .link,
            linkURL: url.absoluteString,
            linkTitle: metadata.title,
            linkDescription: metadata.description,
            linkThumbnailURL: metadata.imageURL
        )
    }

    private static func nakedLinkAttachment(for url: URL) -> AttachedFileContext {
        AttachedFileContext(
            name: url.host ?? url.absoluteString,
            extractedText: nil,
            kind: .link,
            linkURL: url.absoluteString,
            linkTitle: nil,
            linkDescription: nil,
            linkThumbnailURL: nil
        )
    }

    private struct LinkMetadata {
        var title: String?
        var description: String?
        var imageURL: String?
    }

    private static func fetchMetadata(_ url: URL) async -> LinkMetadata? {
        var request = URLRequest(url: url, timeoutInterval: fetchTimeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = fetchTimeout
        config.timeoutIntervalForResource = fetchTimeout
        let session = URLSession(configuration: config)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.contains("html") else {
            return nil
        }

        let truncated = data.count > maxBytes ? data.prefix(maxBytes) : data
        guard let html = String(data: Data(truncated), encoding: .utf8)
            ?? String(data: Data(truncated), encoding: .isoLatin1) else {
            return nil
        }

        let head = head(of: html)
        var meta = LinkMetadata()
        meta.title = metaContent(head, property: "og:title")
            ?? metaContent(head, name: "twitter:title")
            ?? titleTag(head)
        meta.description = metaContent(head, property: "og:description")
            ?? metaContent(head, name: "twitter:description")
            ?? metaContent(head, name: "description")
        if let img = metaContent(head, property: "og:image")
            ?? metaContent(head, name: "twitter:image") {
            meta.imageURL = absoluteURLString(img, relativeTo: url)
        }
        return meta
    }

    private static func head(of html: String) -> String {
        guard let range = html.range(of: "</head>", options: [.caseInsensitive]) else {
            return String(html.prefix(maxBytes))
        }
        return String(html[..<range.upperBound])
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        let pattern = #"<meta[^>]+property\s*=\s*['"]"# + NSRegularExpression.escapedPattern(for: property) + #"['"][^>]*>"#
        return contentAttribute(matching: pattern, in: html)
    }

    private static func metaContent(_ html: String, name: String) -> String? {
        let pattern = #"<meta[^>]+name\s*=\s*['"]"# + NSRegularExpression.escapedPattern(for: name) + #"['"][^>]*>"#
        return contentAttribute(matching: pattern, in: html)
    }

    private static func contentAttribute(matching pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsString = html as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range) else { return nil }
        let tag = nsString.substring(with: match.range)
        return contentValue(in: tag)
    }

    private static func contentValue(in tag: String) -> String? {
        let pattern = #"content\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsString = tag as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges >= 2 else { return nil }
        let value = nsString.substring(with: match.range(at: 1))
        return decodeHTMLEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleTag(_ html: String) -> String? {
        let pattern = #"<title[^>]*>([\s\S]*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsString = html as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2 else { return nil }
        let value = nsString.substring(with: match.range(at: 1))
        return decodeHTMLEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absoluteURLString(_ candidate: String, relativeTo base: URL) -> String? {
        if let url = URL(string: candidate), url.scheme != nil {
            return url.absoluteString
        }
        return URL(string: candidate, relativeTo: base)?.absoluteString
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        var s = string
        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        for (escaped, plain) in replacements {
            s = s.replacingOccurrences(of: escaped, with: plain)
        }
        return s
    }
}
