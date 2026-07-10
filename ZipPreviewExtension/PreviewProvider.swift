import QuickLookUI
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
    }

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL

        let entries: [ZipEntry]
        do {
            entries = try listZipEntries(from: url)
        } catch {
            let html = errorPageHTML(message: "Could not read archive: \(error.localizedDescription)")
            let data = html.data(using: .utf8) ?? Data()
            let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
            completionHandler(reply, nil)
            return
        }

        let html = generateZipHTML(entries: entries, filename: url.lastPathComponent)
        guard let data = html.data(using: .utf8) else {
            completionHandler(nil, NSError(domain: "ZipPreviewError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode HTML"]))
            return
        }

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
        completionHandler(reply, nil)
    }

    // MARK: - ZIP Entry Listing

    private struct ZipEntry {
        let path: String
        let size: UInt32
        let isDirectory: Bool
    }

    private func listZipEntries(from url: URL) throws -> [ZipEntry] {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 22 else { throw ZipError.invalidArchive }

        var eocdPos = count - 22
        let searchStart = max(count - 65557, 0)
        while eocdPos >= searchStart {
            if bytes[eocdPos] == 0x50 && bytes[eocdPos+1] == 0x4b &&
               bytes[eocdPos+2] == 0x05 && bytes[eocdPos+3] == 0x06 {
                break
            }
            eocdPos -= 1
        }
        guard eocdPos >= searchStart else { throw ZipError.invalidArchive }

        let readU16: (Int) -> UInt16 = { pos in
            UInt16(bytes[pos]) | (UInt16(bytes[pos+1]) << 8)
        }
        let readU32: (Int) -> UInt32 = { pos in
            UInt32(bytes[pos]) | (UInt32(bytes[pos+1]) << 8) |
            (UInt32(bytes[pos+2]) << 16) | (UInt32(bytes[pos+3]) << 24)
        }

        let cdOffset = Int(readU32(eocdPos + 16))
        let numEntries = Int(readU16(eocdPos + 10))

        var entries: [ZipEntry] = []
        var pos = cdOffset

        for _ in 0..<numEntries {
            guard pos + 46 <= count else { break }
            guard bytes[pos] == 0x50 && bytes[pos+1] == 0x4b &&
                  bytes[pos+2] == 0x01 && bytes[pos+3] == 0x02 else { break }

            let nameLen = Int(readU16(pos + 28))
            let extraLen = Int(readU16(pos + 30))
            let commentLen = Int(readU16(pos + 32))
            let uncompSize = readU32(pos + 24)
            let nameStart = pos + 46

            guard nameStart + nameLen <= count else { break }
            let name = String(bytes: bytes[nameStart..<nameStart+nameLen], encoding: .utf8)
                ?? "invalid-name"

            let isDir = name.hasSuffix("/") || uncompSize == 0
            entries.append(ZipEntry(path: name, size: uncompSize, isDirectory: isDir))
            pos += 46 + nameLen + extraLen + commentLen
        }

        return entries
    }

    private enum ZipError: Error { case invalidArchive }

    // MARK: - HTML Generation

    private func generateZipHTML(entries: [ZipEntry], filename: String) -> String {
        let totalFiles = entries.filter { !$0.isDirectory }.count
        let totalDirs = entries.filter { $0.isDirectory }.count

        let rows = entries.isEmpty
            ? "<div class=\"empty\">Archive is empty</div>"
            : entries.map { entry -> String in
                let sizeStr = entry.isDirectory ? "" : formatSize(entry.size)
                let cls = entry.isDirectory ? "entry dir" : "entry"
                return """
                <div class="\(cls)">
                    <span class="name">\(escapeHTML(entry.path))</span>
                    \(sizeStr.isEmpty ? "" : "<span class=\"size\">\(sizeStr)</span>")
                </div>
                """
            }.joined()

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{
                font-family:-apple-system,'SF Mono',Menlo,monospace;
                font-size:12px;background:#1e1e1e;color:#d4d4d4;
                padding:16px;overflow-y:auto;
            }
            .header{
                border-bottom:1px solid #333;
                padding-bottom:10px;margin-bottom:12px;
            }
            .filename{
                color:#569cd6;font-size:14px;font-weight:600;
            }
            .summary{
                color:#808080;font-size:11px;margin-top:4px;
            }
            .entry{
                display:flex;justify-content:space-between;
                padding:6px 10px;border-bottom:1px solid #2a2a2a;
            }
            .entry:last-child{border-bottom:none}
            .entry.dir{background:rgba(86,156,214,0.05)}
            .entry .name{color:#d4d4d4;word-break:break-all;flex:1;min-width:0}
            .entry.dir .name{color:#569cd6}
            .entry .size{
                color:#808080;margin-left:16px;white-space:nowrap;
                flex-shrink:0;
            }
            .empty{
                color:#808080;font-style:italic;text-align:center;
                padding:40px;font-size:13px;
            }
        </style></head>
        <body>
            <div class="header">
                <div class="filename">\(escapeHTML(filename))</div>
                <div class="summary">\(totalFiles) files, \(totalDirs) directories</div>
            </div>
            \(rows)
        </body>
        </html>
        """
    }

    private func errorPageHTML(message: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:-apple-system,sans-serif;background:#1e1e1e;color:#888;
                 display:flex;align-items:center;justify-content:center;height:100vh;
                 padding:40px;text-align:center;font-size:14px}
        </style></head><body><p>\(escapeHTML(message))</p></body></html>
        """
    }

    // MARK: - Utilities

    private func formatSize(_ bytes: UInt32) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func escapeHTML(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
