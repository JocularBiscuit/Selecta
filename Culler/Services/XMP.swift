import Foundation

/// Minimal XMP sidecar reader/writer.
///
/// We write the Adobe-conventional base-name sidecar (`DSC01234.xmp`) with
/// `xmp:Rating` and `xmp:Label`. Lightroom Classic and Bridge read these
/// reliably when the sidecar sits next to the RAW. Pick/reject flags are NOT
/// part of standard XMP, so they stay app-internal.
enum XMP {

    struct Values {
        var rating: Int = 0
        var label: ColorLabel?
    }

    // MARK: Writing

    static func packet(rating: Int, label: ColorLabel?) -> String {
        let labelAttr = label.map { "\n      xmp:Label=\"\($0.rawValue)\"" } ?? ""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Selecta 1.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="\(max(0, min(5, rating)))"\(labelAttr)/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// Sidecar URL for an item. `includeExtension` = `DSC01234.ARW.xmp` style;
    /// otherwise the Adobe-default `DSC01234.xmp`.
    static func sidecarURL(for item: CardItem, includeExtension: Bool) -> URL? {
        guard let anchor = item.rawURL ?? item.jpegURL ?? item.videoURL else { return nil }
        if includeExtension {
            return anchor.appendingPathExtension("xmp")
        }
        return anchor.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Write (or remove, when rating==0 and no label and no existing sidecar)
    /// the sidecar for an item. Failures are silently ignored — cards can be
    /// locked/read-only and ratings still live in the local database.
    @discardableResult
    static func write(for item: CardItem, includeExtension: Bool) -> Bool {
        guard let url = sidecarURL(for: item, includeExtension: includeExtension) else { return false }
        let text = packet(rating: item.rating, label: item.label)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Write a sidecar next to an exported file.
    @discardableResult
    static func write(rating: Int, label: ColorLabel?, nextTo exportedFile: URL, includeExtension: Bool) -> Bool {
        let url = includeExtension
            ? exportedFile.appendingPathExtension("xmp")
            : exportedFile.deletingPathExtension().appendingPathExtension("xmp")
        do {
            try packet(rating: rating, label: label).data(using: .utf8)?.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Reading

    /// Parse `xmp:Rating` and `xmp:Label` from a sidecar. Handles both the
    /// attribute form (`xmp:Rating="3"`) and element form
    /// (`<xmp:Rating>3</xmp:Rating>`), which covers Lightroom/Bridge output.
    static func read(from url: URL) -> Values? {
        guard let data = try? Data(contentsOf: url),
              data.count < 2_000_000,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var values = Values()
        var found = false

        if let r = firstMatch(in: text, pattern: #"xmp:Rating\s*=\s*"(-?\d+)""#)
            ?? firstMatch(in: text, pattern: #"<xmp:Rating>\s*(-?\d+)\s*</xmp:Rating>"#) {
            values.rating = max(0, min(5, Int(r) ?? 0))
            found = true
        }
        if let l = firstMatch(in: text, pattern: #"xmp:Label\s*=\s*"([^"]*)""#)
            ?? firstMatch(in: text, pattern: #"<xmp:Label>\s*([^<]*?)\s*</xmp:Label>"#) {
            values.label = ColorLabel(rawValue: l)
            found = true
        }
        return found ? values : nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
