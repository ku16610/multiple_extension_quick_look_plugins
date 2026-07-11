import QuickLookUI

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
    }

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL

        let info = parseKolyBlock(from: url)
        let html = infoHTML(dmgInfo: info, filename: url.lastPathComponent)

        guard let data = html.data(using: .utf8) else {
            completionHandler(nil, NSError(domain: "DmgPreviewError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode HTML"]))
            return
        }
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
        completionHandler(reply, nil)
    }

    private enum DmgError: Error {
        case mountFailed(detail: String)
        var localizedDescription: String {
            switch self { case .mountFailed(let d): return "Mount failed: \(d)" }
        }
    }

    private struct DmgInfo {
        let partitions: [(name: String, size: String)]
        let summary: String
    }

    // MARK: - Fallback: parse DMG koly block directly (no external tools)

    private func parseKolyBlock(from url: URL) -> DmgInfo {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return DmgInfo(partitions: [], summary: "Disk image")
        }
        defer { try? fh.close() }

        guard let fileSize = try? fh.seekToEnd(), fileSize >= 512 else {
            return DmgInfo(partitions: [], summary: "Disk image")
        }

        // Read the last 512 bytes where the koly block lives
        try? fh.seek(toOffset: fileSize - 512)
        let raw = fh.readData(ofLength: 512)
        let bytes = [UInt8](raw)
        guard bytes.count == 512 else {
            return DmgInfo(partitions: [], summary: "Disk image")
        }

        // Check for koly signature at end (standard) or start (older DMGs)
        let pos: Int
        if bytes[0] == 0x6b && bytes[1] == 0x6f && bytes[2] == 0x6c && bytes[3] == 0x79 {
            pos = 0
        } else {
            // Maybe it's at the start of the file (some DMG variants)
            try? fh.seek(toOffset: 0)
            let head = fh.readData(ofLength: 4)
            let headBytes = [UInt8](head)
            if headBytes.count == 4 && headBytes[0] == 0x6b && headBytes[1] == 0x6f &&
               headBytes[2] == 0x6c && headBytes[3] == 0x79 {
                // Koly at start - read from beginning
                try? fh.seek(toOffset: 0)
                let fullHead = fh.readData(ofLength: min(Int(fileSize), 512))
                let hb = [UInt8](fullHead)
                guard hb.count >= 512 else { return DmgInfo(partitions: [], summary: "Disk image") }
                return parseKolyBytes(hb, start: 0, fileSize: Int(fileSize))
            }
            return DmgInfo(partitions: [], summary: "Disk image (\(formatSize(UInt64(fileSize))))")
        }

        return parseKolyBytes(bytes, start: pos, fileSize: Int(fileSize))
    }

    private func parseKolyBytes(_ bytes: [UInt8], start: Int, fileSize: Int) -> DmgInfo {
        let readU32: (Int) -> UInt32 = { offset in
            let p = start + offset
            return UInt32(bytes[p]) | (UInt32(bytes[p+1]) << 8) |
                   (UInt32(bytes[p+2]) << 16) | (UInt32(bytes[p+3]) << 24)
        }
        let readU64: (Int) -> UInt64 = { offset in
            let p = start + offset
            return UInt64(bytes[p]) | (UInt64(bytes[p+1]) << 8) |
                   (UInt64(bytes[p+2]) << 16) | (UInt64(bytes[p+3]) << 24) |
                   (UInt64(bytes[p+4]) << 32) | (UInt64(bytes[p+5]) << 40) |
                   (UInt64(bytes[p+6]) << 48) | (UInt64(bytes[p+7]) << 56)
        }

        let dataSize = readU64(0x20)
        let blockCount = readU64(0x10)
        let isCompressed = (readU32(0x0c) & 1) != 0

        var summary = "\(formatSize(UInt64(fileSize)))"
        if isCompressed {
            let ratio = fileSize > 0 ? Double(dataSize) / Double(fileSize) * 100 : 0
            summary += " \u{2022} \(formatSize(dataSize)) uncompressed (\(Int(ratio))%)"
        }
        var partitions: [(name: String, size: String)] = [
            ("File size", formatSize(UInt64(fileSize))),
        ]
        if dataSize > 0 && dataSize != UInt64(fileSize) {
            partitions.append(("Data (uncompressed)", formatSize(dataSize)))
        }
        if blockCount > 0 {
            partitions.append(("Blocks", "\(blockCount)"))
        }
        partitions.append(("Compressed", isCompressed ? "Yes" : "No"))
        return DmgInfo(partitions: partitions, summary: summary)
    }

    // MARK: - HTML Generators

    private func infoHTML(dmgInfo: DmgInfo, filename: String) -> String {
        let rows = dmgInfo.partitions.isEmpty
            ? "<div class=\"entry\">\(escapeHTML(dmgInfo.summary))</div>"
            : dmgInfo.partitions.map { p -> String in
                """
                <div class="entry">
                    <span class="name">\(escapeHTML(p.name))</span>
                    <span class="size">\(escapeHTML(p.size))</span>
                </div>
                """
            }.joined()

        return pageHTML(title: filename, summary: dmgInfo.summary, body: rows)
    }

    private func pageHTML(title: String, summary: String, body: String) -> String {
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
            .filename{color:#569cd6;font-size:14px;font-weight:600}
            .summary{color:#808080;font-size:11px;margin-top:4px}
            .entry{
                display:flex;justify-content:space-between;
                padding:6px 10px;border-bottom:1px solid #2a2a2a;
            }
            .entry:last-child{border-bottom:none}
            .entry.dir{background:rgba(86,156,214,0.05)}
            .entry .name{color:#d4d4d4;word-break:break-all;flex:1;min-width:0}
            .entry.dir .name{color:#569cd6}
            .entry .size{color:#808080;margin-left:16px;white-space:nowrap;flex-shrink:0}
            .empty{color:#808080;font-style:italic;text-align:center;padding:40px;font-size:13px}
        </style></head>
        <body>
            <div class="header">
                <div class="filename">\(escapeHTML(title))</div>
                <div class="summary">\(escapeHTML(summary))</div>
            </div>
            \(body)
        </body>
        </html>
        """
    }

    private func makeReply(_ message: String) -> QLPreviewReply {
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:-apple-system,sans-serif;background:#1e1e1e;color:#888;
                 display:flex;align-items:center;justify-content:center;height:100vh;
                 padding:40px;text-align:center;font-size:14px}
        </style></head><body><p>\(escapeHTML(message))</p></body></html>
        """
        let data = html.data(using: .utf8) ?? Data()
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
    }

    // MARK: - Utilities

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    private func escapeHTML(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
