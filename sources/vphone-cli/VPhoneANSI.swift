import Foundation

/// Strips terminal control noise from captured child output before it reaches a
/// log pane. The build pipeline (aria2c, tqdm, brew) emits ANSI colour codes and
/// cursor moves that an `NSTextView` renders as garbage; this removes the escape
/// sequences and stray C0 controls while preserving `\n`, `\r`, and `\t` so the
/// caller can still do its own carriage-return / line handling.
enum VPhoneANSI {
    /// Keep tab/newline/carriage-return; drop other C0 controls and DEL.
    private static func isStrippableControl(_ v: UInt32) -> Bool {
        if v == 0x09 || v == 0x0A || v == 0x0D { return false }
        return v < 0x20 || v == 0x7F
    }

    static func strip(_ s: String) -> String {
        // Fast path: nothing to clean.
        if !s.unicodeScalars.contains(where: { $0 == "\u{1B}" || isStrippableControl($0.value) }) {
            return s
        }

        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" {
                guard i + 1 < scalars.count else { break } // lone trailing ESC
                let n = scalars[i + 1]
                if n == "[" {
                    // CSI: ESC [ … <final 0x40–0x7E>
                    i += 2
                    while i < scalars.count, !(scalars[i].value >= 0x40 && scalars[i].value <= 0x7E) {
                        i += 1
                    }
                    if i < scalars.count { i += 1 }
                } else if n == "]" {
                    // OSC: ESC ] … (BEL | ESC \)
                    i += 2
                    while i < scalars.count {
                        if scalars[i] == "\u{07}" { i += 1; break }
                        if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "\\" {
                            i += 2; break
                        }
                        i += 1
                    }
                } else {
                    i += 2 // two-char escape (e.g. ESC ( B)
                }
                continue
            }
            if isStrippableControl(c.value) { i += 1; continue }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
