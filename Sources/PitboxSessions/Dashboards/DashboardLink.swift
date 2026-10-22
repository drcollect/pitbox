import Darwin
import Foundation

/// One accepted dashboard link: its site and its handle.
struct DashboardLinkHit: Equatable, Sendable {
    var site: CodeDashboardSite
    var handle: String
}

/// The dashboard link grammar for the configured sites
/// (`CodeDashboardSites`): `https://<host><pathPrefix><handle>/`, also without the scheme, without the trailing slash, or
/// followed by one `[a-z0-9._-]+.html` file name; in plain text, inline code, bold, a Markdown link's target or its
/// text; trailing sentence punctuation, a query and a fragment ignored. The host is exactly a site's host (lowercase,
/// no port, no user info, no other label before it), `http://` and every other scheme are refused, and the handle passes
/// the site's check (`CodeDashboardSite.isValidHandle`: `^[a-z0-9]+(?:-[a-z0-9]+)*$`, 1-64 characters, and its own
/// pattern). Only the site and the handle are kept: the address is always rebuilt from them (`CodeDashboard.url`), never
/// taken from the text. No site: nothing is ever found. Works on UTF-8 bytes; pure.
enum DashboardLink {
    private static let https: [UInt8] = Array("https://".utf8)
    private static let http: [UInt8] = Array("http://".utf8)
    private static let html: [UInt8] = Array(".html".utf8)

    /// The handles of every accepted link in `text`, in text order (any site).
    static func handles(in text: String, sites: CodeDashboardSites) -> [String] { links(in: text, sites: sites).map(\.handle) }

    /// Every accepted link in `text`, in text order.
    static func links(in text: String, sites: CodeDashboardSites) -> [DashboardLinkHit] {
        var copy = text
        return copy.withUTF8 { links(in: UnsafeRawBufferPointer($0), sites: sites) }
    }

    /// The last accepted link in `text`.
    static func newestLink(in text: String, sites: CodeDashboardSites) -> DashboardLinkHit? { links(in: text, sites: sites).last }

    /// Whether `bytes` hold a site's marker at all (cheap: one `memmem` per site).
    static func mayHoldLink(_ bytes: UnsafeRawBufferPointer, sites: CodeDashboardSites) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return sites.all.contains { site in
            let marker = site.marker
            guard bytes.count >= marker.count else { return false }
            return marker.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, marker.count) } != nil
        }
    }

    /// Every accepted link in `bytes`, in order.
    static func links(in bytes: UnsafeRawBufferPointer, sites: CodeDashboardSites) -> [DashboardLinkHit] {
        guard let base = bytes.baseAddress else { return [] }
        let b = bytes.bindMemory(to: UInt8.self)
        var out: [(at: Int, hit: DashboardLinkHit)] = []
        for site in sites.all {
            let marker = site.marker
            guard b.count >= marker.count else { continue }
            var from = 0
            while from < b.count {
                let found = marker.withUnsafeBytes { needle in
                    memmem(base + from, b.count - from, needle.baseAddress, marker.count)
                }
                guard let found else { break }
                let at = base.distance(to: UnsafeRawPointer(found))
                if let handle = handle(b, markerAt: at, site: site) {
                    out.append((at, DashboardLinkHit(site: site, handle: handle)))
                }
                from = at + marker.count
            }
        }
        return out.sorted { $0.at < $1.at }.map(\.hit)
    }

    // MARK: One link

    /// The handle of the link whose marker (`site`'s) starts at `p`, when everything around it fits the grammar.
    private static func handle(_ b: UnsafeBufferPointer<UInt8>, markerAt p: Int, site: CodeDashboardSite) -> String? {
        guard acceptsPrefix(b, before: p) else { return nil }
        var i = p + site.marker.count
        let start = i
        while i < b.count, isHandleByte(b[i]) { i += 1 }
        let handleBytes = Array(b[start..<i])
        guard let handle = String(bytes: handleBytes, encoding: .utf8), site.isValidHandle(handle) else {
            return nil
        }
        if i < b.count, b[i] == 0x2F {
            // "/" and then nothing, a sentence's punctuation, or one `.html` file name.
            i += 1
            let fileStart = i
            while i < b.count, isFileByte(b[i]) { i += 1 }
            var fileEnd = i
            while fileEnd > fileStart, b[fileEnd - 1] == 0x2E { fileEnd -= 1 }
            if fileEnd > fileStart {
                let name = Array(b[fileStart..<fileEnd])
                guard name.count > html.count, name.suffix(html.count).elementsEqual(html) else { return nil }
            }
            i = fileEnd
        } else if i < b.count, b[i] == 0x2E || b[i] == 0x3A {
            // "." or ":" right after the handle only as punctuation (not "polar-shore.html", not ":8443").
            guard i + 1 >= b.count || isTerminator(b, at: i + 1) else { return nil }
        }
        if i < b.count, b[i] == 0x3F || b[i] == 0x23 {
            // A query or a fragment: ignored up to the end of the link.
            while i < b.count, !isTerminator(b, at: i) || b[i] == 0x2E || b[i] == 0x3A { i += 1 }
        }
        guard i >= b.count || isTerminator(b, at: i) else { return nil }
        return handle
    }

    /// The scheme is `https://` or absent; nothing that belongs to a host, a path or user info sits before it.
    private static func acceptsPrefix(_ b: UnsafeBufferPointer<UInt8>, before p: Int) -> Bool {
        if p >= https.count, b[(p - https.count)..<p].elementsEqual(https) {
            let q = p - https.count
            return q == 0 || !isSchemeByte(b[q - 1])
        }
        if p >= http.count, b[(p - http.count)..<p].elementsEqual(http) { return false }
        guard p > 0 else { return true }
        let c = b[p - 1]
        // A letter, digit, `.`, `-` or `_` would make another host; `@` user info; `/` and `:` another URL's path or
        // scheme; `%` an encoding.
        return !(isAlphanumeric(c) || c == 0x2E || c == 0x2D || c == 0x5F || c == 0x40 || c == 0x2F || c == 0x3A
            || c == 0x25)
    }

    /// What may follow a link: the end, whitespace, ASCII punctuation and Markdown marks, or a typographic quote,
    /// dash, ellipsis or no-break space.
    private static func isTerminator(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        guard i < b.count else { return true }
        let c = b[i]
        switch c {
        case 0x20, 0x09, 0x0A, 0x0D: return true
        case 0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x7D, 0x3E, 0x27, 0x22, 0x60, 0x2A, 0x5F, 0x7C, 0x3C:
            return true
        case 0xC2: return i + 1 < b.count && b[i + 1] == 0xA0
        case 0xE2:
            guard i + 2 < b.count, b[i + 1] == 0x80 else { return false }
            return [0x93, 0x94, 0x98, 0x99, 0x9C, 0x9D, 0xA6].contains(b[i + 2])
        default: return false
        }
    }

    private static func isHandleByte(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D }

    private static func isFileByte(_ c: UInt8) -> Bool { isHandleByte(c) || c == 0x2E || c == 0x5F }

    private static func isAlphanumeric(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isSchemeByte(_ c: UInt8) -> Bool { isAlphanumeric(c) || c == 0x2B || c == 0x2D || c == 0x2E }
}
