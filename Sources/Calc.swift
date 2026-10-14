import Foundation

/// Inline calculator: `45+32/658`, `2^10`, `sqrt(2)*pi`, `15% * 80`, `1,250 x 3`.
/// Only answers input that has at least one operator or function, so typing a
/// plain number (or an app name) never shows a result.
enum Calc {
    static func evaluate(_ input: String) -> Double? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("=") { s.removeFirst() }
        if s.hasSuffix("=") { s.removeLast() }
        guard let tokens = tokenize(s), !tokens.isEmpty else { return nil }
        var p = Parser(tokens: tokens)
        guard let v = p.expression(), p.atEnd, p.ops > 0, v.isFinite else { return nil }
        return v
    }

    /// `grouping` adds thousands separators, for display; the copied value has none.
    static func format(_ v: Double, grouping: Bool) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e15 || a < 1e-9 { return String(format: "%.10g", v) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale.current
        f.maximumFractionDigits = 10
        f.usesGroupingSeparator = grouping
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    enum Token: Equatable {
        case num(Double)
        case op(Character)
        case lparen, rparen
        case ident(String)
    }

    static func tokenize(_ s: String) -> [Token]? {
        let c = Array(s)
        var out: [Token] = []
        var i = 0
        func isDigit(_ i: Int) -> Bool { i < c.count && c[i].isASCII && c[i].isNumber }
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if isDigit(i) || (ch == "." && isDigit(i + 1)) {
                var text = ""
                var dot = false
                while i < c.count {
                    if isDigit(i) {
                        text.append(c[i])
                    } else if c[i] == "." {
                        if dot { return nil } // 1.2.3 is a version, not a number
                        dot = true
                        text.append(".")
                    } else if c[i] == ",", !dot, isDigit(i + 1), isDigit(i + 2), isDigit(i + 3), !isDigit(i + 4) {
                        // A thousands separator: 1,250
                    } else if c[i] == "e" || c[i] == "E" {
                        // Scientific notation, when digits follow: 2e3, 1.5e-4
                        var j = i + 1
                        if j < c.count, c[j] == "+" || c[j] == "-" { j += 1 }
                        guard isDigit(j) else { break }
                        text += "e" + String(c[(i + 1)..<j])
                        i = j
                        while isDigit(i) { text.append(c[i]); i += 1 }
                        break
                    } else {
                        break
                    }
                    i += 1
                }
                guard let v = Double(text) else { return nil }
                out.append(.num(v))
                continue
            }
            switch ch {
            case "+", "-", "/", "^", "%", "!":
                out.append(.op(ch))
            case "*":
                if i + 1 < c.count, c[i + 1] == "*" {
                    out.append(.op("^"))
                    i += 1
                } else {
                    out.append(.op("*"))
                }
            case "×", "·": out.append(.op("*"))
            case "÷": out.append(.op("/"))
            case "−", "–": out.append(.op("-"))
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case "π": out.append(.ident("pi"))
            default:
                guard ch.isLetter else { return nil }
                // "x" between numbers multiplies: 3x4, 3 x 4
                if ch == "x" || ch == "X", let last = out.last, last.endsValue {
                    out.append(.op("*"))
                    i += 1
                    continue
                }
                var name = ""
                while i < c.count, c[i].isLetter || (!name.isEmpty && isDigit(i)) {
                    name.append(c[i])
                    i += 1
                }
                out.append(.ident(name.lowercased()))
                continue
            }
            i += 1
        }
        return out
    }

    static let constants: [String: Double] = ["pi": .pi, "e": M_E, "tau": 2 * .pi]
    static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "abs": { Swift.abs($0) },
        "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
        "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
        "ln": { log($0) }, "log": { log10($0) }, "log10": { log10($0) }, "log2": { log2($0) },
        "exp": { exp($0) }, "floor": { floor($0) }, "ceil": { ceil($0) }, "round": { $0.rounded() },
    ]

    /// Recursive descent, loosest first: + -, then * / % (and 2pi, 3(4)), unary
    /// minus, ^ (right-associative, so -2^2 = -4), postfix % and !.
    struct Parser {
        let tokens: [Token]
        var i = 0
        /// Operators and functions seen: a lone number isn't worth answering.
        var ops = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool { i >= tokens.count }
        var peek: Token? { atEnd ? nil : tokens[i] }

        func peekOp(_ offset: Int = 0) -> Character? {
            guard i + offset < tokens.count, case .op(let o) = tokens[i + offset] else { return nil }
            return o
        }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let o = peekOp(), o == "+" || o == "-" {
                i += 1
                ops += 1
                guard let r = term() else { return nil }
                v = o == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = unary() else { return nil }
            while true {
                if let o = peekOp(), o == "*" || o == "/" || o == "%" {
                    i += 1
                    ops += 1
                    guard let r = unary() else { return nil }
                    switch o {
                    case "*": v *= r
                    case "/": v /= r
                    default: v = v.truncatingRemainder(dividingBy: r)
                    }
                } else if let t = peek, t == .lparen || t.isIdent {
                    // Implicit multiplication: 2pi, 3(4+1), 2 sqrt(9)
                    ops += 1
                    guard let r = unary() else { return nil }
                    v *= r
                } else {
                    return v
                }
            }
        }

        mutating func unary() -> Double? {
            if let o = peekOp(), o == "-" || o == "+" {
                i += 1
                guard let v = unary() else { return nil }
                return o == "-" ? -v : v
            }
            return power()
        }

        mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            if peekOp() == "^" {
                i += 1
                ops += 1
                guard let exp = unary() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while let o = peekOp() {
                if o == "%" && percentIsPostfix() {
                    v /= 100
                } else if o == "!" {
                    guard v >= 0, v <= 170, v == v.rounded() else { return nil }
                    v = tgamma(v + 1)
                } else {
                    break
                }
                i += 1
                ops += 1
            }
            return v
        }

        /// `50%` and `15% * 80` are percentages; `10 % 3` is a remainder.
        func percentIsPostfix() -> Bool {
            guard i + 1 < tokens.count else { return true }
            switch tokens[i + 1] {
            case .rparen, .op: return true
            default: return false
            }
        }

        mutating func primary() -> Double? {
            guard let t = peek else { return nil }
            i += 1
            switch t {
            case .num(let v):
                return v
            case .lparen:
                guard let v = expression() else { return nil }
                // Closing parens are optional at the end, so a result shows while typing.
                if peek == .rparen { i += 1 } else if !atEnd { return nil }
                return v
            case .ident(let name):
                if let k = constants[name] { return k }
                guard let f = functions[name] else { return nil }
                ops += 1
                // sin(x)^2 squares the sine; sqrt 2^2 takes the root of 4.
                guard let arg = peek == .lparen ? primary() : power() else { return nil }
                return f(arg)
            default:
                return nil
            }
        }
    }
}

extension Calc.Token {
    var isIdent: Bool { if case .ident = self { return true } else { return false } }
    /// Ends an operand, so an "x" after it means times.
    var endsValue: Bool {
        switch self {
        case .num, .rparen, .ident: return true
        case .op(let o): return o == "%" || o == "!"
        case .lparen: return false
        }
    }
}
