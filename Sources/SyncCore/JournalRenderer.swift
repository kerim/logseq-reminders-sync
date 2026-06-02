import Foundation

// date-fns uses Unicode TR35 tokens, the same family as DateFormatter/ICU, so
// feeding individual tokens to DateFormatter is valid for everything except `do`
// (ordinal day), which DateFormatter doesn't support and is computed manually.

/// Returns the rendered journal title for `date` using the date-fns-style `format`
/// string, or `nil` if the format contains an unrecognized ASCII-letter token
/// (signals: safe-degrade, do not create a journal page).
///
/// Pass the *same* `calendar` instance to both this function and `journalDay(for:calendar:)`
/// so a single `Date` always maps to one consistent civil day.
public func renderJournalTitle(date: Date, format: String, calendar: Calendar) -> String? {
    // Sorted longest-first so longer patterns shadow shorter prefixes (e.g. "MMMM" before "MMM").
    let knownTokens = ["EEEE", "MMMM", "yyyy", "EEE", "MMM", "dd", "do", "yy", "MM", "d", "M"]

    var result = ""
    var i = format.startIndex

    while i < format.endIndex {
        let ch = format[i]

        // Single-quoted literal per Unicode TR35: 'text' → emit text verbatim.
        if ch == "'" {
            let afterOpen = format.index(after: i)
            if let closeIdx = format[afterOpen...].firstIndex(of: "'") {
                result += format[afterOpen..<closeIdx]
                i = format.index(after: closeIdx)
            } else {
                result += format[afterOpen...]  // unclosed quote: emit rest as literal
                break
            }
            continue
        }

        // ASCII letter: try to match a known token (longest first).
        // Unquoted non-letters (spaces, commas, slashes) fall through to the literal path below.
        if ch.isASCII && ch.isLetter {
            var matched = false
            for token in knownTokens {
                guard let tokenEnd = format.index(i, offsetBy: token.count, limitedBy: format.endIndex)
                else { continue }
                if format[i..<tokenEnd] == token {
                    result += renderToken(token, date: date, calendar: calendar)
                    i = tokenEnd
                    matched = true
                    break
                }
            }
            if !matched {
                return nil  // unrecognized ASCII-letter run — safe-degrade
            }
            continue
        }

        // Non-letter, non-quote: emit verbatim (commas, spaces, slashes, etc.).
        result.append(ch)
        i = format.index(after: i)
    }

    return result
}

/// Returns the Logseq journal-day integer (YYYYMMDD) for `date` in the `calendar`'s
/// timezone — matching how Logseq keys `:block/journal-day` by the user's civil date.
public func journalDay(for date: Date, calendar: Calendar) -> Int {
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    return comps.year! * 10000 + comps.month! * 100 + comps.day!
}

// MARK: - Private

private func renderToken(_ token: String, date: Date, calendar: Calendar) -> String {
    if token == "do" {
        let day = calendar.component(.day, from: date)
        return "\(day)\(ordinalSuffix(day))"
    }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.calendar = calendar
    df.timeZone = calendar.timeZone
    df.dateFormat = token
    return df.string(from: date)
}

private func ordinalSuffix(_ n: Int) -> String {
    switch n % 100 {
    case 11, 12, 13: return "th"  // teen exceptions override the ones-digit rule
    default: break
    }
    switch n % 10 {
    case 1: return "st"
    case 2: return "nd"
    case 3: return "rd"
    default: return "th"
    }
}
