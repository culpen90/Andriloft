import Foundation

// A small, non-executing HTML reader. APKMirror serves its catalog and file metadata
// in the initial document; navigation scripts and advertisements are never selectors.
final class APKMirrorHTMLNode {
    let tag: String
    let attributes: [String: String]
    var children: [APKMirrorHTMLNode] = []
    weak var parent: APKMirrorHTMLNode?
    private let content: String

    init(tag: String, attributes: [String: String] = [:], content: String = "") {
        self.tag = tag; self.attributes = attributes; self.content = content
    }
    var text: String {
        if tag == "#text" { return content }
        if tag == "br" { return "\n" }
        return children.map(\.text).joined(separator: " ")
    }
    var trimmedText: String { text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    func hasClass(_ value: String) -> Bool { (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).contains(Substring(value)) }
    func descendants(where predicate: (APKMirrorHTMLNode) -> Bool) -> [APKMirrorHTMLNode] {
        children.flatMap { child in (predicate(child) ? [child] : []) + child.descendants(where: predicate) }
    }
    func first(where predicate: (APKMirrorHTMLNode) -> Bool) -> APKMirrorHTMLNode? {
        for child in children {
            if predicate(child) { return child }
            if let nested = child.first(where: predicate) { return nested }
        }
        return nil
    }
    func ancestor(where predicate: (APKMirrorHTMLNode) -> Bool) -> APKMirrorHTMLNode? {
        var node = parent
        while let current = node { if predicate(current) { return current }; node = current.parent }
        return nil
    }
}

struct APKMirrorHTML {
    let root: APKMirrorHTMLNode
    let isValid: Bool

    init(_ html: String) {
        let cleaned = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, with: "", options: .regularExpression)
        root = APKMirrorHTMLNode(tag: "#document")
        var stack = [root]
        var nodeCount = 0, valid = true
        let tokens = Self.matches(#"<(?:(?:\"[^\"]*\"|'[^']*'|[^'\">])*)>|[^<]+"#, cleaned)
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        for token in tokens {
            nodeCount += 1
            guard nodeCount <= 100_000, stack.count <= 256 else { valid = false; break }
            if !token.hasPrefix("<") {
                let node = APKMirrorHTMLNode(tag: "#text", content: Self.decode(token))
                node.parent = stack.last; stack.last?.children.append(node)
                continue
            }
            guard !token.hasPrefix("<!"), !token.hasPrefix("<?") else { continue }
            if token.hasPrefix("</") {
                let tag = token.dropFirst(2).prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 { stack.removeSubrange(index...) }
                continue
            }
            let tag = token.dropFirst().prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
            guard !tag.isEmpty else { continue }
            var attributes: [String: String] = [:]
            let remaining = String(token.dropFirst(tag.count + 1).dropLast())
            for match in Self.groups(#"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#, remaining) {
                let value = match.dropFirst().first(where: { !$0.isEmpty }) ?? ""
                attributes[match[0].lowercased()] = Self.decode(value)
            }
            let node = APKMirrorHTMLNode(tag: tag, attributes: attributes)
            node.parent = stack.last; stack.last?.children.append(node)
            if !voidTags.contains(tag), !token.hasSuffix("/>") { stack.append(node) }
        }
        isValid = valid
    }

    var main: APKMirrorHTMLNode { root.first { ["content", "primary"].contains($0.attributes["id"] ?? "") } ?? root }
    static func matches(_ pattern: String, _ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { Range($0.range, in: value).map { String(value[$0]) } }
    }
    static func groups(_ pattern: String, _ value: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { result in
            (1..<result.numberOfRanges).map { Range(result.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
        }
    }
    static func decode(_ value: String) -> String {
        let named = ["amp":"&", "lt":"<", "gt":">", "quot":"\"", "apos":"'", "nbsp":" ", "ndash":"–", "mdash":"—", "hellip":"…", "rsquo":"’", "lsquo":"‘", "rdquo":"”", "ldquo":"“", "copy":"©", "reg":"®", "trade":"™", "bull":"•"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: result), let nameRange = Range(match.range(at: 1), in: value) else { continue }
            let name = String(value[nameRange])
            var replacement = named[name]
            if name.hasPrefix("#") {
                let hex = name.lowercased().hasPrefix("#x")
                if let number = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            }
            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }
        return result
    }
}
