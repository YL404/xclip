import Foundation

/// 打标入参：`"slug"` 引用已有标签，`"slug:中文名"` 内联新建标签。
public struct TagInput: Equatable, Sendable {
    public let slug: String
    public let chineseName: String?

    public init(slug: String, chineseName: String? = nil) {
        self.slug = slug
        self.chineseName = chineseName
    }
}

/// 双语标签归一化：英文 slug 只收 ASCII，中文 name 必须真含中文。
public enum TagNormalizer {
    /// 归一化为英文 slug：小写、非字母数字折叠为连字符、收拢重复 `-`、去首尾 `-`。
    /// 含任何非 ASCII 字母/数字（如中文、全角字符）直接拒绝——中文名不能当英文 slug。
    public static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { ($0.isLetter || $0.isNumber) && !$0.isASCII }) {
            return nil
        }
        var out: [Character] = []
        for character in trimmed.lowercased() {
            if character == "-" || character.isLetter || character.isNumber {
                if character == "-" {
                    if out.last != "-" { out.append("-") }
                } else {
                    out.append(character)
                }
            } else if out.last != "-" {
                out.append("-")
            }
        }
        let slug = String(out).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    /// 归一化中文标签名：去掉首尾空白；空串、换行、不含中文字符的都拒绝。
    public static func normalizeChineseName(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        let hasChinese = trimmed.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
        return hasChinese ? trimmed : nil
    }

    /// 解析打标入参：支持 `"slug"`、`"slug:中文名"`、`"slug：中文名"`（取第一个分隔符切开）。
    /// 前半段必须是合法英文 slug，给了分隔符时后半段必须是合法中文名。
    public static func parseTagInput(_ raw: String) throws -> TagInput {
        if let sep = raw.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            guard let slug = normalize(String(raw[..<sep])) else {
                throw TagStoreError.invalidSlug(raw)
            }
            guard let name = normalizeChineseName(String(raw[raw.index(after: sep)...])) else {
                throw TagStoreError.invalidChineseName(raw)
            }
            return TagInput(slug: slug, chineseName: name)
        }
        guard let slug = normalize(raw) else {
            throw TagStoreError.invalidSlug(raw)
        }
        return TagInput(slug: slug)
    }
}
