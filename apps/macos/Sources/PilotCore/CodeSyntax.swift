import Foundation

/// Lightweight lexical highlighting for common languages, including incomplete streamed code.
/// Tokens retain the source verbatim. Unknown languages intentionally remain plain text, and so does "shell", the
/// label tool output uses. This is not a parser: regex literals, string interpolation and nested comments are not
/// interpreted. Large sources are meant to be tokenized off the main thread.
public enum CodeSyntax {
    public enum Kind: Equatable, Sendable {
        case keyword, string, number, comment, literal, function
    }

    public struct Token: Equatable, Sendable {
        public let text: String
        public let kind: Kind?
    }

    public static func tokens(_ source: String, language: String?) -> [Token] {
        let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let language, let profile = profile(for: language) else {
            return [Token(text: source, kind: nil)]
        }

        let text = source as NSString
        var tokens: [Token] = []
        var offset = 0
        for match in profile.lexer.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            if match.range.location > offset {
                tokens.append(Token(text: text.substring(with: NSRange(location: offset, length: match.range.location - offset)), kind: nil))
            }
            let value = text.substring(with: match.range)
            let kind: Kind?
            if match.range(withName: "comment").location != NSNotFound {
                kind = .comment
            } else if match.range(withName: "string").location != NSNotFound {
                kind = .string
            } else if match.range(withName: "number").location != NSNotFound {
                kind = .number
            } else if profile.keywords.contains(profile.caseInsensitive ? value.lowercased() : value) {
                kind = .keyword
            } else if profile.literals.contains(profile.caseInsensitive ? value.lowercased() : value) {
                kind = .literal
            } else if match.range(withName: "function").location != NSNotFound {
                kind = .function
            } else {
                kind = nil
            }
            tokens.append(Token(text: value, kind: kind))
            offset = NSMaxRange(match.range)
        }
        if offset < text.length {
            tokens.append(Token(text: text.substring(from: offset), kind: nil))
        }
        return tokens
    }

    /// The language name `tokens` understands for a file path, from its extension or well-known name.
    public static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "makefile", ".zshrc", ".bashrc", ".env", ".env.example": return "sh"
        default: break
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return profile(for: ext) == nil ? nil : ext
    }

    // MARK: Profiles

    private struct Profile {
        let keywords: Set<String>
        let literals: Set<String>
        let lexer: NSRegularExpression
        var caseInsensitive = false
    }

    private static func profile(for language: String) -> Profile? {
        switch language {
        case "javascript", "js", "mjs", "cjs", "jsx", "typescript", "ts", "tsx", "mts", "cts": javascript
        case "swift": swift
        case "python", "py": python
        case "rust", "rs": rust
        case "go", "golang": go
        case "kotlin", "kt", "kts", "java": jvm
        case "c", "h", "cpp", "cc", "hpp", "cxx", "objc", "m", "mm", "c++", "csharp", "cs": cFamily
        case "ruby", "rb": ruby
        case "bash", "sh", "zsh": sh
        case "sql", "psql", "pgsql": sql
        case "json", "jsonc", "json5": json
        case "yaml", "yml", "toml": yaml
        case "css", "scss": css
        default: nil
        }
    }

    // Shared pieces. In `allowCommentsAndWhitespace` mode `#` starts a regex comment, so it is escaped.
    private static let slashComments = #"//[^\r\n]* | /\*[\s\S]*?(?:\*/|\z)"#
    private static let hashComments = ##"\#[^\r\n]*"##
    private static let dashComments = #"--[^\r\n]* | /\*[\s\S]*?(?:\*/|\z)"#
    private static let doubleQuoted = #""(?:\\(?:[\s\S]|\z)|[^"\\\r\n])*(?:"|(?=\r|\n|\z))"#
    private static let singleQuoted = #"'(?:\\(?:[\s\S]|\z)|[^'\\\r\n])*(?:'|(?=\r|\n|\z))"#
    private static let backtick = #"`(?:\\(?:[\s\S]|\z)|[^`\\])*(?:`|\z)"#
    private static let tripleDouble = "\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"
    private static let tripleSingle = #"'''[\s\S]*?(?:'''|\z)"#
    private static let number = #"""
        \b0[xX][\da-fA-F_]+n? | \b0[bB][01_]+n? | \b0[oO][0-7_]+n?
        | (?:\b\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?[\d_]+)?n?
        """#
    private static let identifier = #"[$\p{L}_][$\p{L}\p{N}_‌‍]*"#

    /// Comments and strings come before identifiers, so their contents are never highlighted as code.
    private static func lexer(comments: String?, strings: [String]) -> NSRegularExpression {
        var parts: [String] = []
        if let comments { parts.append("(?<comment> \(comments) )") }
        parts.append("(?<string> \(strings.joined(separator: " | ")) )")
        parts.append("(?<number> \(number) )")
        parts.append("(?<function> \(identifier)(?=\\s*\\() )")
        parts.append(identifier)
        return try! NSRegularExpression(pattern: parts.joined(separator: "\n| "), options: .allowCommentsAndWhitespace)
    }

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    private static let cLiterals = words("true false null nil")

    // Template literals are styled as a single string, including their interpolation expressions.
    private static let javascript = Profile(
        keywords: words("""
            as async await break case catch class const continue debugger declare default delete do else enum export \
            extends finally for from function get if implements import in instanceof interface keyof let namespace new \
            of private protected public readonly return satisfies set static super switch this throw try type typeof \
            var void while with yield
            """),
        literals: words("true false null undefined NaN Infinity"),
        lexer: lexer(comments: slashComments, strings: [doubleQuoted, singleQuoted, backtick]))

    private static let swift = Profile(
        keywords: words("""
            actor associatedtype async await break case catch class continue default defer deinit do else enum extension \
            fallthrough fileprivate final for func guard if import in init inout internal is let mutating nonisolated \
            open operator override private protocol public repeat rethrows return self Self some static struct \
            subscript super switch throw throws try typealias var weak where while any
            """),
        literals: words("true false nil"),
        lexer: lexer(comments: slashComments, strings: [tripleDouble, doubleQuoted]))

    private static let python = Profile(
        keywords: words("""
            and as assert async await break class continue def del elif else except finally for from global if import \
            in is lambda match case nonlocal not or pass raise return try while with yield self
            """),
        literals: words("True False None"),
        lexer: lexer(comments: hashComments, strings: [tripleDouble, tripleSingle, doubleQuoted, singleQuoted]))

    private static let rust = Profile(
        keywords: words("""
            as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move \
            mut pub ref return self Self static struct super trait type unsafe use where while
            """),
        literals: words("true false None Some Ok Err"),
        lexer: lexer(comments: slashComments, strings: [doubleQuoted]))

    private static let go = Profile(
        keywords: words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface map \
            package range return select struct switch type var
            """),
        literals: words("true false nil iota"),
        lexer: lexer(comments: slashComments, strings: [doubleQuoted, backtick, singleQuoted]))

    private static let jvm = Profile(
        keywords: words("""
            abstract as break case catch class companion const continue data default do else enum extends final \
            finally for fun if implements import in interface is new object override package private protected \
            public return sealed static super suspend switch this throw throws try val var void when while
            """),
        literals: cLiterals,
        lexer: lexer(comments: slashComments, strings: [tripleDouble, doubleQuoted, singleQuoted]))

    private static let cFamily = Profile(
        keywords: words("""
            auto break case catch class const constexpr continue default delete do else enum extern for friend goto \
            if include define inline namespace new private protected public return sizeof static struct switch \
            template this throw try typedef typename union unsigned signed using virtual void volatile while \
            int char float double long short bool var
            """),
        literals: words("true false NULL nullptr nil YES NO null"),
        lexer: lexer(comments: slashComments, strings: [doubleQuoted, singleQuoted]))

    private static let ruby = Profile(
        keywords: words("""
            alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo \
            rescue retry return self super then unless until when while yield require
            """),
        literals: words("true false nil"),
        lexer: lexer(comments: hashComments, strings: [doubleQuoted, singleQuoted]))

    private static let sh = Profile(
        keywords: words("""
            if then else elif fi for while until do done case esac in function return local export source exit set \
            unset readonly shift trap
            """),
        literals: words("true false"),
        lexer: lexer(comments: hashComments, strings: [doubleQuoted, singleQuoted]))

    private static let sql = Profile(
        keywords: words("""
            select from where and or not in is as join left right inner outer full on group by order having limit \
            offset insert into values update set delete create alter drop table index view primary key foreign \
            references unique default distinct union all case when then else end with returning begin commit \
            rollback asc desc exists between like ilike
            """),
        literals: words("true false null"),
        lexer: lexer(comments: dashComments, strings: [singleQuoted, doubleQuoted]),
        caseInsensitive: true)

    private static let json = Profile(
        keywords: [], literals: words("true false null"),
        lexer: lexer(comments: slashComments, strings: [doubleQuoted]))

    private static let yaml = Profile(
        keywords: [], literals: words("true false null yes no on off"),
        lexer: lexer(comments: hashComments, strings: [doubleQuoted, singleQuoted]))

    private static let css = Profile(
        keywords: words("important media import supports keyframes from to"),
        literals: [],
        lexer: lexer(comments: #"/\*[\s\S]*?(?:\*/|\z)"#, strings: [doubleQuoted, singleQuoted]))
}
