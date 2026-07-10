import QuickLookUI
import WebKit

// MARK: - Principal Class (view-based)

class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        view = webView
    }

    override func beginRequest(with context: NSExtensionContext) {}

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier else {
            showMessage("Could not determine file type")
            handler(nil)
            return
        }

        if uti == "com.microsoft.ini" || uti == "public.plain-text" || uti == "public.text" {
            showIniPreview(url: url)
            handler(nil)
        } else if uti == "public.zip-archive" || uti == "com.pkware.zip-archive" {
            showZipPreview(url: url)
            handler(nil)
        } else {
            showMessage("Unsupported file type")
            handler(nil)
        }
    }

    // MARK: - INI Preview

    private func showIniPreview(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            showMessage("Could not read file as UTF-8 text")
            return
        }
        let html = generateIniHTML(from: content, filename: url.lastPathComponent)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - ZIP Preview (async with loading state)

    private func showZipPreview(url: URL) {
        webView.loadHTMLString(loadingPageHTML, baseURL: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = (try? self.listZipEntries(from: url)) ?? []
            let html = self.generateZipHTML(entries: entries, filename: url.lastPathComponent)
            DispatchQueue.main.async {
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    // MARK: - Helpers

    private func showMessage(_ message: String) {
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:-apple-system,sans-serif;background:#1e1e1e;color:#888;
                 display:flex;align-items:center;justify-content:center;height:100vh;
                 padding:40px;text-align:center;font-size:14px}
        </style></head><body><p>\(escapeHTML(message))</p></body></html>
        """
        webView?.loadHTMLString(html, baseURL: nil)
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

        // Find End of Central Directory (EOCD) signature
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

    // MARK: - HTML Generators

    private let loadingPageHTML = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{
            font-family:-apple-system,sans-serif;
            background:#1e1e1e;color:#ccc;
            display:flex;flex-direction:column;
            align-items:center;justify-content:center;
            height:100vh;gap:16px;
        }
        .spinner{
            width:36px;height:36px;
            border:3px solid #333;
            border-top-color:#0a84ff;
            border-radius:50%;
            animation:spin .8s linear infinite;
        }
        @keyframes spin{to{transform:rotate(360deg)}}
        .label{font-size:13px;color:#888}
    </style></head>
    <body>
        <div class="spinner"></div>
        <div class="label">Reading archive&hellip;</div>
    </body>
    </html>
    """

    private func generateZipHTML(entries: [ZipEntry], filename: String) -> String {
        let totalFiles = entries.filter { !$0.isDirectory }.count
        let totalDirs = entries.filter { $0.isDirectory }.count

        let rows = entries.isEmpty
            ? "<div class=\"empty\">Archive is empty</div>"
            : entries.map { entry -> String in
                let icon = entry.isDirectory ? "&#128193;" : "&#128196;"
                let sizeStr = entry.isDirectory ? "" : formatSize(entry.size)
                let cls = entry.isDirectory ? "entry dir" : "entry"
                let name = escapeHTML(entry.path)
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

    private func generateIniHTML(from content: String, filename: String) -> String {
        let sections = parseINI(content)

        let sectionsHTML = sections.isEmpty
            ? "<div class=\"empty\">Empty INI file</div>"
            : sections.map { section -> String in
                var html = "<div class=\"section\">"
                if !section.name.isEmpty {
                    html += "<div class=\"section-header\">[\(escapeHTML(section.name))]</div>"
                }
                for comment in section.comments {
                    html += "<div class=\"comment\">; \(escapeHTML(comment))</div>"
                }
                for pair in section.pairs {
                    html += """
                    <div class="pair">
                        <span class="key">\(escapeHTML(pair.key))</span>
                        <span class="separator"> = </span>
                        <span class="value">\(escapeHTML(pair.value))</span>
                    </div>
                    """
                }
                html += "</div>"
                return html
            }.joined()

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{
                font-family:-apple-system,'SF Mono',Menlo,Monaco,'Courier New',monospace;
                font-size:13px;background:#1e1e1e;color:#d4d4d4;padding:24px;overflow-y:auto;
            }
            .header{border-bottom:1px solid #333;padding-bottom:12px;margin-bottom:20px}
            .filename{color:#569cd6;font-size:15px;font-weight:600}
            .section{
                margin:0 0 12px 0;padding:10px 14px;background:#252526;
                border-left:3px solid #569cd6;border-radius:4px;
            }
            .section-header{color:#569cd6;font-weight:700;font-size:14px;margin-bottom:8px}
            .pair{margin:3px 0 3px 14px;display:flex;gap:4px}
            .key{color:#9cdcfe}
            .separator{color:#808080}
            .value{color:#ce9178;word-break:break-all}
            .comment{color:#6a9955;font-style:italic;margin:2px 0 2px 14px}
            .empty{color:#808080;font-style:italic;padding:20px;text-align:center}
        </style></head>
        <body>
            <div class="header">
                <div class="filename">\(escapeHTML(filename))</div>
            </div>
            \(sectionsHTML)
        </body>
        </html>
        """
    }

    // MARK: - INI Parser

    private struct Section {
        let name: String
        let pairs: [(key: String, value: String)]
        let comments: [String]
    }

    private func parseINI(_ content: String) -> [Section] {
        var sections: [Section] = []
        var currentSectionName = ""
        var currentPairs: [(String, String)] = []
        var currentComments: [String] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                currentComments.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }

            if trimmed.hasPrefix("[") {
                let sectionName = trimmed
                    .trimmingCharacters(in: .whitespaces)
                    .dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespaces)
                if !currentSectionName.isEmpty || !currentPairs.isEmpty || !currentComments.isEmpty {
                    sections.append(Section(name: currentSectionName, pairs: currentPairs, comments: currentComments))
                }
                currentSectionName = String(sectionName)
                currentPairs = []
                currentComments = []
                continue
            }

            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
                currentPairs.append((key, value))
            }
        }

        if !currentSectionName.isEmpty || !currentPairs.isEmpty || !currentComments.isEmpty {
            sections.append(Section(name: currentSectionName, pairs: currentPairs, comments: currentComments))
        }

        return sections
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
