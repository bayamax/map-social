import SwiftUI

/// 本文中のURLをタップで開けるリンクとして表示するテキスト。
/// SwiftUIのTextはAttributedStringの.link属性を自動でタップ可能にするので、
/// NSDataDetectorでURLを検出して属性を付けるだけでよい。
struct LinkedText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Self.attributed(text))
    }

    /// URL部分に.link属性(青・下線)を付けたAttributedStringを作る。
    /// 長いURLは「🔗 ドメイン名」の短縮表示にする(リンク先はそのまま)。
    static func attributed(_ s: String) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(s)
        }
        var result = AttributedString()
        var cursor = s.startIndex
        let ns = s as NSString
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s), let url = m.url else { continue }
            if cursor < r.lowerBound {
                result += AttributedString(String(s[cursor..<r.lowerBound]))
            }
            var link = AttributedString(displayLabel(url: url, original: String(s[r])))
            link.link = url
            link.foregroundColor = .blue
            link.underlineStyle = .single
            result += link
            cursor = r.upperBound
        }
        if cursor < s.endIndex {
            result += AttributedString(String(s[cursor...]))
        }
        return result
    }

    /// リンクの表示ラベル。短いURLはそのまま、長いものは「🔗 ドメイン」に短縮
    private static func displayLabel(url: URL, original: String) -> String {
        if original.count <= 30 { return original }
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        return host.isEmpty ? original : "🔗 \(host)"
    }

    /// URLを取り除いた本文（地図の吹き出し用。リンクは詳細を開いた先でタップできる）
    static func stripped(_ s: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return s
        }
        let ns = NSMutableString(string: s)
        let matches = detector.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            ns.replaceCharacters(in: m.range, with: "")
        }
        return (ns as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
