// Estrazione allegati (oggetti OLE incorporati) da documenti Office — implementazione Swift pura.
// Nessuna dipendenza: lettore ZIP (Compression), lettore OLE2/CFB, parser EMF per la didascalia icona.
import Foundation
import Compression

struct ExtractedFile {
    var name: String
    var data: Data
    var kind: String
}

struct ExtractionResult {
    var files: [ExtractedFile] = []
    var warnings: [String] = []
}

enum ExtractError: LocalizedError {
    case unsupported(String)
    case corrupt(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Formato non riconosciuto: \(s)"
        case .corrupt(let s): return "File danneggiato: \(s)"
        }
    }
}

// MARK: - Byte helpers

extension Data {
    func u16(_ off: Int) -> UInt16 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt16.self) }.littleEndian }
    func u32(_ off: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }.littleEndian }
    func slice(_ off: Int, _ len: Int) -> Data {
        let s = Swift.max(0, Swift.min(off, count)), e = Swift.max(s, Swift.min(off + len, count))
        return subdata(in: (startIndex + s)..<(startIndex + e))
    }
    func starts(with bytes: [UInt8]) -> Bool { count >= bytes.count && Array(prefix(bytes.count)) == bytes }
}

// MARK: - ZIP reader (stored + deflate)

struct ZipEntry { let name: String; let method: UInt16; let compSize: Int; let uncompSize: Int; let localOffset: Int }

final class ZipReader {
    let data: Data
    private(set) var entries: [String: ZipEntry] = [:]

    init(data: Data) throws {
        self.data = data
        // End of central directory
        var eocd = -1
        var i = data.count - 22
        while i >= Swift.max(0, data.count - 66000) {
            if data.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ExtractError.corrupt("archivio ZIP senza directory centrale") }
        let cdCount = Int(data.u16(eocd + 10))
        var p = Int(data.u32(eocd + 16))
        for _ in 0..<cdCount {
            guard p + 46 <= data.count, data.u32(p) == 0x02014b50 else { break }
            let method = data.u16(p + 10)
            let comp = Int(data.u32(p + 20)), uncomp = Int(data.u32(p + 24))
            let nLen = Int(data.u16(p + 28)), eLen = Int(data.u16(p + 30)), cLen = Int(data.u16(p + 32))
            let off = Int(data.u32(p + 42))
            let name = String(data: data.slice(p + 46, nLen), encoding: .utf8) ?? ""
            entries[name] = ZipEntry(name: name, method: method, compSize: comp, uncompSize: uncomp, localOffset: off)
            p += 46 + nLen + eLen + cLen
        }
    }

    var names: [String] { Array(entries.keys) }

    func read(_ name: String) -> Data? {
        guard let e = entries[name], e.localOffset + 30 <= data.count, data.u32(e.localOffset) == 0x04034b50 else { return nil }
        let nLen = Int(data.u16(e.localOffset + 26)), xLen = Int(data.u16(e.localOffset + 28))
        let start = e.localOffset + 30 + nLen + xLen
        let raw = data.slice(start, e.compSize)
        switch e.method {
        case 0: return raw
        case 8: return inflate(raw, expected: e.uncompSize)
        default: return nil
        }
    }

    private func inflate(_ src: Data, expected: Int) -> Data? {
        if expected == 0 { return Data() }
        let dstSize = expected
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let n = src.withUnsafeBytes { (sp: UnsafeRawBufferPointer) -> Int in
            compression_decode_buffer(dst, dstSize, sp.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        return n == dstSize ? Data(bytes: dst, count: n) : (n > 0 ? Data(bytes: dst, count: n) : nil)
    }
}

// MARK: - OLE2 / Compound File Binary reader

final class OleFile {
    struct Entry { let name: String; let type: UInt8; let start: UInt32; let size: Int; let left: UInt32; let right: UInt32; let child: UInt32; let clsid: String; var path: [String] = [] }
    let data: Data
    let sectorSize: Int
    let miniSectorSize: Int
    let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var miniStream: Data = Data()
    private(set) var entries: [Entry] = []
    private(set) var rootClsid: String = ""

    static let ENDOFCHAIN: UInt32 = 0xFFFFFFFE
    static let FREESECT: UInt32 = 0xFFFFFFFF

    static func isOle(_ d: Data) -> Bool { d.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) }

    init(data: Data) throws {
        guard OleFile.isOle(data), data.count >= 512 else { throw ExtractError.corrupt("non è un compound file OLE") }
        self.data = data
        sectorSize = 1 << Int(data.u16(0x1E))
        miniSectorSize = 1 << Int(data.u16(0x20))
        miniCutoff = Int(data.u32(0x38))
        let fatCount = Int(data.u32(0x2C))
        let dirStart = data.u32(0x30)
        let miniFatStart = data.u32(0x3C), miniFatCount = Int(data.u32(0x40))
        var difatNext = data.u32(0x44)
        let difatCount = Int(data.u32(0x48))

        // DIFAT
        var fatSectors: [UInt32] = []
        for i in 0..<109 { let s = data.u32(0x4C + i * 4); if s < 0xFFFFFFFA { fatSectors.append(s) } }
        var guardN = 0
        while difatNext < 0xFFFFFFFA && guardN < difatCount + 1 {
            let off = sectorOffset(difatNext)
            let per = sectorSize / 4 - 1
            for i in 0..<per { let s = data.u32(off + i * 4); if s < 0xFFFFFFFA { fatSectors.append(s) } }
            difatNext = data.u32(off + per * 4); guardN += 1
        }
        _ = fatCount
        // FAT
        fat.reserveCapacity(fatSectors.count * sectorSize / 4)
        for s in fatSectors {
            let off = sectorOffset(s)
            guard off + sectorSize <= data.count else { continue }
            for i in 0..<(sectorSize / 4) { fat.append(data.u32(off + i * 4)) }
        }
        // Directory
        let dirData = readChainSelf(start: dirStart, size: nil)
        var raw: [Entry] = []
        var p = 0
        while p + 128 <= dirData.count {
            let nameLen = Int(dirData.u16(p + 64))
            let type = dirData[dirData.startIndex + p + 66]
            if type != 0 && nameLen >= 2 {
                let nameBytes = dirData.slice(p, nameLen - 2)
                let name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
                let clsid = OleFile.clsidString(dirData.slice(p + 80, 16))
                raw.append(Entry(name: name, type: type, start: dirData.u32(p + 116), size: Int(dirData.u32(p + 120)),
                                 left: dirData.u32(p + 68), right: dirData.u32(p + 72), child: dirData.u32(p + 76), clsid: clsid))
            } else {
                raw.append(Entry(name: "", type: 0, start: 0, size: 0, left: 0xFFFFFFFF, right: 0xFFFFFFFF, child: 0xFFFFFFFF, clsid: ""))
            }
            p += 128
        }
        rootClsid = raw.first?.clsid ?? ""
        // Mini FAT + mini stream
        if let root = raw.first {
            miniStream = readChainSelf(start: root.start, size: root.size)
        }
        if miniFatCount > 0 && miniFatStart < 0xFFFFFFFA {
            let mf = readChainSelf(start: miniFatStart, size: nil)
            for i in 0..<(mf.count / 4) { miniFat.append(mf.u32(i * 4)) }
        }
        // Walk tree to assign paths
        var out: [Entry] = []
        func walk(_ idx: UInt32, _ prefix: [String], _ depth: Int) {
            guard idx != 0xFFFFFFFF, Int(idx) < raw.count, depth < 64 else { return }
            var e = raw[Int(idx)]
            if e.type == 0 { return }
            walk(e.left, prefix, depth + 1)
            e.path = prefix + [e.name]
            out.append(e)
            if e.type == 1 { walk(e.child, e.path, depth + 1) }
            walk(e.right, prefix, depth + 1)
        }
        if let root = raw.first { walk(root.child, [], 0) }
        entries = out
    }

    private func sectorOffset(_ s: UInt32) -> Int { (Int(s) + 1) * sectorSize }

    private func readChainSelf(start: UInt32, size: Int?) -> Data {
        var out = Data()
        var s = start
        var n = 0
        let limit = data.count / sectorSize + 2
        while s < 0xFFFFFFFA && n < limit {
            let off = sectorOffset(s)
            guard off < data.count else { break }
            out.append(data.slice(off, sectorSize))
            guard Int(s) < fat.count else { break }
            s = fat[Int(s)]; n += 1
        }
        if let sz = size, out.count > sz { out = out.prefix(sz) }
        return out
    }

    private func readMiniChain(start: UInt32, size: Int) -> Data {
        var out = Data()
        var s = start
        var n = 0
        let limit = miniStream.count / miniSectorSize + 2
        while s < 0xFFFFFFFA && n < limit {
            let off = Int(s) * miniSectorSize
            guard off < miniStream.count else { break }
            out.append(miniStream.slice(off, miniSectorSize))
            guard Int(s) < miniFat.count else { break }
            s = miniFat[Int(s)]; n += 1
        }
        return out.count > size ? out.prefix(size) : out
    }

    func entry(_ path: [String]) -> Entry? { entries.first { $0.path == path && $0.type == 2 } }
    func exists(_ path: [String]) -> Bool { entry(path) != nil }

    func stream(_ path: [String]) -> Data? {
        guard let e = entry(path) else { return nil }
        if e.size < miniCutoff { return readMiniChain(start: e.start, size: e.size) }
        return readChainSelf(start: e.start, size: e.size)
    }

    /// Stream entries under a storage path
    func streams(under storage: [String]) -> [Entry] {
        entries.filter { $0.type == 2 && $0.path.count == storage.count + 1 && Array($0.path.prefix(storage.count)) == storage }
    }
    func storages(under storage: [String]) -> [Entry] {
        entries.filter { $0.type == 1 && $0.path.count == storage.count + 1 && Array($0.path.prefix(storage.count)) == storage }
    }

    static func clsidString(_ d: Data) -> String {
        guard d.count == 16 else { return "" }
        let b = [UInt8](d)
        if b.allSatisfy({ $0 == 0 }) { return "" }
        let a = String(format: "%02X%02X%02X%02X", b[3], b[2], b[1], b[0])
        let c = String(format: "%02X%02X", b[5], b[4])
        let e = String(format: "%02X%02X", b[7], b[6])
        let f = b[8...15].map { String(format: "%02X", $0) }.joined()
        return "\(a)-\(c)-\(e)-\(f.prefix(4))-\(f.suffix(12))"
    }
}

// MARK: - Extractor

enum Extractor {
    static let supportedExtensions: Set<String> = ["docx","docm","dotx","dotm","doc","dot","xlsx","xlsm","xltx","xltm","xls","xlt","pptx","pptm","potx","ppt","pot"]

    static let clsidExt: [String: String] = [
        "00020906-0000-0000-C000-000000000046": "doc",
        "00020820-0000-0000-C000-000000000046": "xls",
        "00020810-0000-0000-C000-000000000046": "xls",
        "64818D10-4F9B-11CF-86EA-00AA00B929E8": "ppt",
        "00020D0B-0000-0000-C000-000000000046": "msg",
        "00021A14-0000-0000-C000-000000000046": "vsd",
    ]

    static func extract(_ data: Data, filename: String) throws -> ExtractionResult {
        var res = ExtractionResult()
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            try extractOOXML(data, &res)
        } else if OleFile.isOle(data) {
            try extractLegacy(data, &res)
        } else {
            throw ExtractError.unsupported(filename)
        }
        var used = Set<String>()
        for i in res.files.indices { res.files[i].name = unique(&used, safeName(res.files[i].name)) }
        return res
    }

    // MARK: helpers
    static func safeName(_ n: String) -> String {
        var s = n.replacingOccurrences(of: "\\", with: "/")
        s = String(s.split(separator: "/").last ?? Substring(s))
        let bad = CharacterSet(charactersIn: "<>:\"|?*").union(.controlCharacters)
        s = String(String.UnicodeScalarView(s.unicodeScalars.map { bad.contains($0) ? "_" : $0 }))
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return s.isEmpty ? "allegato" : s
    }

    static func unique(_ used: inout Set<String>, _ name: String) -> String {
        var cand = name
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 1
        while used.contains(cand.lowercased()) {
            i += 1
            cand = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
        }
        used.insert(cand.lowercased())
        return cand
    }

    static func sniffExt(_ d: Data, default def: String = "bin") -> String {
        if d.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if d.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            if let z = try? ZipReader(data: d) {
                let n = z.names
                if n.contains(where: { $0.hasPrefix("word/") }) { return "docx" }
                if n.contains(where: { $0.hasPrefix("xl/") }) { return "xlsx" }
                if n.contains(where: { $0.hasPrefix("ppt/") }) { return "pptx" }
            }
            return "zip"
        }
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if d.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if d.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if d.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]) { return "rtf" }
        if OleFile.isOle(d) { return "ole" }
        if d.starts(with: [0x4D, 0x5A]) { return "exe" }
        if d.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { return "7z" }
        if d.starts(with: [0x52, 0x61, 0x72, 0x21]) { return "rar" }
        return def
    }

    static func cString(_ d: Data, _ pos: inout Int) -> String {
        var end = pos
        while end < d.count && d[d.startIndex + end] != 0 { end += 1 }
        let s = String(data: d.slice(pos, end - pos), encoding: .windowsCP1252) ?? String(decoding: d.slice(pos, end - pos), as: UTF8.self)
        pos = end + 1
        return s
    }

    /// Stream \u{1}Ole10Native: (nome file originale, dati)
    static func parseOle10Native(_ s: Data) -> (String, Data)? {
        guard s.count > 12 else { return nil }
        var pos = 6
        let label = cString(s, &pos)
        let path = cString(s, &pos)
        pos += 4
        guard pos + 4 <= s.count else { return nil }
        let tmpLen = Int(s.u32(pos)); pos += 4 + tmpLen
        guard pos + 4 <= s.count else { return nil }
        let dataLen = Int(s.u32(pos)); pos += 4
        guard dataLen >= 0, pos + dataLen <= s.count else { return nil }
        let name = safeName(label.isEmpty ? path : label)
        return (name, s.slice(pos, dataLen))
    }

    static func compObjProgId(_ ole: OleFile, _ base: [String]) -> String {
        guard let buf = ole.stream(base + ["\u{1}CompObj"]) else { return "" }
        var pos = 28, parts: [String] = []
        for _ in 0..<3 {
            guard pos + 4 <= buf.count else { break }
            let ln = Int(buf.u32(pos)); pos += 4
            guard ln >= 0, ln < 1024, pos + ln <= buf.count else { break }
            var d = buf.slice(pos, ln)
            while let l = d.last, l == 0 { d.removeLast() }
            if let s = String(data: d, encoding: .windowsCP1252), !s.isEmpty { parts.append(s) }
            pos += ln
        }
        return parts.joined(separator: " | ")
    }

    /// Estrae l'oggetto contenuto in un OLE (file .bin intero oppure storage annidato)
    static func extractFromOle(_ ole: OleFile, base: [String], raw: Data?, fallback: String, source: String, _ res: inout ExtractionResult) {
        let progid = compObjProgId(ole, base)
        if let s = ole.stream(base + ["\u{1}Ole10Native"]) {
            if let (name, d) = parseOle10Native(s) {
                res.files.append(ExtractedFile(name: name, data: d, kind: "File incorporato (Package)"))
            } else {
                res.warnings.append("\(source): stream Ole10Native malformato")
            }
            return
        }
        if let d = ole.stream(base + ["CONTENTS"]) {
            let ext = sniffExt(d)
            let kind = ext == "pdf" ? "Documento PDF" : "Oggetto \(progid.isEmpty ? "OLE" : progid)"
            res.files.append(ExtractedFile(name: "\(fallback).\(ext)", data: d, kind: kind))
            return
        }
        if let d = ole.stream(base + ["Package"]) {
            res.files.append(ExtractedFile(name: "\(fallback).\(sniffExt(d))", data: d, kind: "Package"))
            return
        }
        // Compound intero (Excel / Word / PowerPoint / Outlook incorporato)
        let streamNames = Set(ole.streams(under: base).map { $0.name })
        let clsid = base.isEmpty ? ole.rootClsid : (ole.entries.first { $0.path == base }?.clsid ?? "")
        var ext = clsidExt[clsid.uppercased()]
        if ext == nil {
            if streamNames.contains("Workbook") || streamNames.contains("Book") { ext = "xls" }
            else if streamNames.contains("WordDocument") { ext = "doc" }
            else if streamNames.contains("PowerPoint Document") { ext = "ppt" }
            else if streamNames.contains("__properties_version1.0") { ext = "msg" }
        }
        if let raw = raw {
            res.files.append(ExtractedFile(name: "\(fallback).\(ext ?? "bin")", data: raw, kind: "Oggetto OLE \(progid.isEmpty ? clsid : progid)".trimmingCharacters(in: .whitespaces)))
        } else {
            res.warnings.append("\(source): oggetto \(progid.isEmpty ? "OLE" : progid) incorporato come storage annidato (\(ext ?? "tipo sconosciuto")) — non estraibile come file singolo")
        }
    }

    // MARK: EMF caption
    static func emfCaption(_ d: Data) -> String {
        var parts: [String] = []
        var pos = 0
        while pos + 8 <= d.count {
            let type = d.u32(pos), size = Int(d.u32(pos + 4))
            if size < 8 { break }
            if type == 84, pos + 52 <= d.count { // EMR_EXTTEXTOUTW
                let nchars = Int(d.u32(pos + 44)), off = Int(d.u32(pos + 48))
                if nchars > 0, nchars < 4096, pos + off + nchars * 2 <= d.count,
                   let s = String(data: d.slice(pos + off, nchars * 2), encoding: .utf16LittleEndian) { parts.append(s) }
            }
            pos += size
        }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: OOXML
    static func regexMatches(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    static func normalize(_ base: String, _ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for c in target.split(separator: "/") {
            if c == ".." { _ = parts.popLast() } else if c != "." { parts.append(String(c)) }
        }
        return parts.joined(separator: "/")
    }

    /// part path -> (ProgID, caption)
    static func ooxmlLabels(_ z: ZipReader, prefix: String) -> [String: (String, String)] {
        var labels: [String: (String, String)] = [:]
        var parts = prefix == "word" ? ["word/document.xml"] : []
        parts += z.names.filter { n in
            n.hasPrefix("\(prefix)/") && n.hasSuffix(".xml") &&
            ["worksheets/", "slides/", "header", "footer"].contains { n.dropFirst(prefix.count + 1).hasPrefix($0) } &&
            !n.contains("_rels")
        }
        for part in parts {
            let dir = (part as NSString).deletingLastPathComponent
            let relsName = "\(dir)/_rels/\((part as NSString).lastPathComponent).rels"
            guard let xmlD = z.read(part), let relsD = z.read(relsName),
                  let xml = String(data: xmlD, encoding: .utf8), let rels = String(data: relsD, encoding: .utf8) else { continue }
            var ridTarget: [String: String] = [:]
            for m in regexMatches("<Relationship\\b[^>]*>", rels) {
                let attrs = Dictionary(regexMatches("([\\w:]+)=\"([^\"]*)\"", m[0]).map { ($0[1], $0[2]) }, uniquingKeysWith: { a, _ in a })
                if let id = attrs["Id"], let t = attrs["Target"] { ridTarget[id] = t }
            }
            var shapeImg: [String: String] = [:]
            for m in regexMatches("<v:shape\\b([^>]*)>(.*?)</v:shape>", xml, options: [.dotMatchesLineSeparators]) {
                if let sid = regexMatches("\\bid=\"([^\"]+)\"", m[1]).first?[1],
                   let img = regexMatches("<v:imagedata\\b[^>]*r:id=\"([^\"]+)\"", m[2]).first?[1] { shapeImg[sid] = img }
            }
            for m in regexMatches("<o:OLEObject\\b([^>]*)>", xml) {
                let attrs = Dictionary(regexMatches("([\\w:]+)=\"([^\"]*)\"", m[1]).map { ($0[1], $0[2]) }, uniquingKeysWith: { a, _ in a })
                guard let rid = attrs["r:id"], let target = ridTarget[rid] else { continue }
                var caption = ""
                if let sid = attrs["ShapeID"], let irid = shapeImg[sid], let it = ridTarget[irid] {
                    let ipart = normalize(dir, it)
                    if ipart.lowercased().hasSuffix(".emf"), let emf = z.read(ipart) { caption = emfCaption(emf) }
                }
                labels[normalize(dir, target)] = (attrs["ProgID"] ?? "", caption)
            }
        }
        return labels
    }

    static func extractOOXML(_ data: Data, _ res: inout ExtractionResult) throws {
        let z = try ZipReader(data: data)
        let names = z.names
        let prefix: String
        if names.contains(where: { $0.hasPrefix("word/") }) { prefix = "word" }
        else if names.contains(where: { $0.hasPrefix("xl/") }) { prefix = "xl" }
        else if names.contains(where: { $0.hasPrefix("ppt/") }) { prefix = "ppt" }
        else { throw ExtractError.unsupported("archivio senza word/ xl/ ppt/") }
        let labels = ooxmlLabels(z, prefix: prefix)
        let emb = names.filter { $0.hasPrefix("\(prefix)/embeddings/") && !$0.hasSuffix("/") }.sorted()
        for (i, n) in emb.enumerated() {
            guard let raw = z.read(n) else { res.warnings.append("\(n): impossibile leggere"); continue }
            let base = (n as NSString).lastPathComponent
            let ext = (base as NSString).pathExtension.lowercased()
            let stem = (base as NSString).deletingPathExtension
            let (progid, caption) = labels[n] ?? ("", "")
            let fallback = caption.isEmpty ? "allegato_\(i + 1)" : (safeName(caption) as NSString).deletingPathExtension
            if ext == "bin" || OleFile.isOle(raw) {
                guard let ole = try? OleFile(data: raw) else { res.warnings.append("\(n): OLE non valido"); continue }
                extractFromOle(ole, base: [], raw: raw, fallback: fallback, source: n, &res)
            } else {
                let realExt = sniffExt(raw, default: ext.isEmpty ? "bin" : ext)
                let generic = stem.lowercased().hasPrefix("microsoft_") || stem.lowercased().hasPrefix("oleobject")
                let name = generic ? "\(fallback).\(realExt)" : base
                res.files.append(ExtractedFile(name: name, data: raw, kind: progid.isEmpty ? "File \(realExt.uppercased())" : progid))
            }
        }
    }

    // MARK: Legacy .doc / .xls / .ppt
    static func extractLegacy(_ data: Data, _ res: inout ExtractionResult) throws {
        let ole = try OleFile(data: data)
        var storages: [[String]] = []
        if ole.entries.contains(where: { $0.path == ["ObjectPool"] && $0.type == 1 }) {
            storages += ole.storages(under: ["ObjectPool"]).map { $0.path }
        }
        storages += ole.storages(under: []).filter { $0.name.hasPrefix("MBD") }.map { $0.path }
        for (i, st) in storages.enumerated() {
            extractFromOle(ole, base: st, raw: nil, fallback: "allegato_\(i + 1)", source: st.joined(separator: "/"), &res)
        }
    }
}
