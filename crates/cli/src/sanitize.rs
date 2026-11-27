//! Terminal output sanitization and human-readable formatting helpers.
//!
//! Server-controlled strings (filenames, bucket names, object keys, error
//! messages, people/album names) MUST pass through [`sanitize_for_tty`] or
//! [`sanitize_multiline`] before being printed so a malicious or corrupted
//! value cannot inject ANSI/VT escape sequences or BiDi overrides into a user's
//! terminal.

/// Strips ANSI/VT escape sequences, C0/C1 control characters, DEL, and Unicode
/// BiDi override characters from a single-line server-controlled string.
/// Whitespace controls (`\r`, `\n`, `\t`) are collapsed into single spaces.
pub fn sanitize_for_tty(input: &str) -> String {
    sanitize_impl(input, false)
}

/// Like [`sanitize_for_tty`], but preserves `\n` and `\t` for multi-line
/// diagnostic output (such as error bodies or text snippets).
pub fn sanitize_multiline(input: &str) -> String {
    sanitize_impl(input, true)
}

fn sanitize_impl(input: &str, allow_multiline: bool) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();

    while let Some(ch) = chars.next() {
        // ESC (0x1B) escape sequences: CSI, OSC, DCS, APC, PM, SOS, or 2-byte ESC.
        if ch == '\x1b' {
            match chars.peek().copied() {
                // CSI: ESC [ <params 0x30..=0x3F>* <intermediates 0x20..=0x2F>* <final 0x40..=0x7E>
                Some('[') => {
                    chars.next();
                    while let Some(&c) = chars.peek() {
                        chars.next();
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC (ESC ]) or string-terminated sequences (DCS P, SOS X, PM ^, APC _)
                Some(']' | 'P' | 'X' | '^' | '_') => {
                    chars.next();
                    while let Some(c) = chars.next() {
                        if c == '\x07' {
                            break;
                        }
                        if c == '\x1b' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                // 2-byte escape sequence (ESC followed by intermediate/final byte)
                Some(c) if (' '..='~').contains(&c) => {
                    chars.next();
                }
                _ => {}
            }
            continue;
        }

        // C1 CSI (U+009B)
        if ch == '\u{009b}' {
            while let Some(&c) = chars.peek() {
                chars.next();
                if ('@'..='~').contains(&c) {
                    break;
                }
            }
            continue;
        }

        // C1 OSC (U+009D) / DCS / PM / APC
        if matches!(
            ch,
            '\u{0090}' | '\u{0098}' | '\u{009d}' | '\u{009e}' | '\u{009f}'
        ) {
            while let Some(c) = chars.next() {
                if c == '\x07' || c == '\u{009c}' {
                    break;
                }
                if c == '\x1b' && chars.peek() == Some(&'\\') {
                    chars.next();
                    break;
                }
            }
            continue;
        }

        // Unicode BiDi control / override characters (CVE-2021-42574 class)
        if matches!(
            ch,
            '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{200e}' | '\u{200f}' | '\u{061c}'
        ) {
            continue;
        }

        if ch == '\n' || ch == '\t' {
            if allow_multiline {
                out.push(ch);
            } else {
                out.push(' ');
            }
            continue;
        }

        if ch == '\r' {
            if !allow_multiline {
                out.push(' ');
            }
            continue;
        }

        // Drop all other C0, DEL, and C1 control characters
        if ch.is_control() {
            continue;
        }

        out.push(ch);
    }

    out
}

/// Formats a byte count in human-readable IEC units.
pub fn format_bytes(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;
    const TIB: f64 = GIB * 1024.0;

    let b = bytes as f64;
    if b >= TIB {
        format!("{:.2} TiB", b / TIB)
    } else if b >= GIB {
        format!("{:.2} GiB", b / GIB)
    } else if b >= MIB {
        format!("{:.1} MiB", b / MIB)
    } else if b >= KIB {
        format!("{:.1} KiB", b / KIB)
    } else {
        format!("{bytes} B")
    }
}

pub fn format_i64_bytes(bytes: i64) -> String {
    if bytes <= 0 {
        "0 B".to_string()
    } else {
        format_bytes(bytes as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_ansi_csi_and_osc_sequences() {
        let evil = "report\x1b[31m-evil\x1b[0m.pdf";
        assert_eq!(sanitize_for_tty(evil), "report-evil.pdf");

        let osc_bel = "hello\x1b]0;pwned-title\x07world";
        assert_eq!(sanitize_for_tty(osc_bel), "helloworld");

        let osc_st = "hello\x1b]52;c;YmFk\x1b\\world";
        assert_eq!(sanitize_for_tty(osc_st), "helloworld");
    }

    #[test]
    fn strips_c0_c1_del_and_bidi_overrides() {
        let evil = "safe\x00\x07\x7f\u{009b}2J\u{202e}fdp.exe";
        assert_eq!(sanitize_for_tty(evil), "safefdp.exe");
    }

    #[test]
    fn preserves_utf8_and_handles_newlines() {
        assert_eq!(
            sanitize_for_tty("Familienversicherung_2026_äöüß.pdf\nline2"),
            "Familienversicherung_2026_äöüß.pdf line2"
        );
        assert_eq!(
            sanitize_multiline("line1\n\tline2\x1b[31m!"),
            "line1\n\tline2!"
        );
    }

    #[test]
    fn formats_byte_sizes() {
        assert_eq!(format_bytes(0), "0 B");
        assert_eq!(format_bytes(512), "512 B");
        assert_eq!(format_bytes(1536), "1.5 KiB");
        assert_eq!(format_bytes(2 * 1024 * 1024), "2.0 MiB");
        assert_eq!(format_bytes(3 * 1024 * 1024 * 1024), "3.00 GiB");
    }
}
