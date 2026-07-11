import QuickLookUI

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
    }

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL

        let info = parsePE(url: url)
        let html = html(info: info, filename: url.lastPathComponent)
        guard let data = html.data(using: .utf8) else {
            completionHandler(nil, NSError(domain: "PePreviewError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode HTML"]))
            return
        }
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
        completionHandler(reply, nil)
    }

    // MARK: - PE Header Parsing

    private struct PEInfo {
        let machine: String
        let is64Bit: Bool
        let subsystem: String
        let characteristics: [String]
        let sections: Int
        let timestamp: String
        let imageSize: UInt32
        let entryPoint: UInt32
        let linkerVersion: String
    }

    private struct PEHeader {
        let coff: COFFHeader
        let optional: OptionalHeader
    }

    private struct COFFHeader {
        let machine: UInt16
        let sections: UInt16
        let timestamp: UInt32
        let characteristics: UInt16
    }

    private struct OptionalHeader {
        let magic: UInt16
        let linkerMajor: UInt8
        let linkerMinor: UInt8
        let addressOfEntryPoint: UInt32
        let imageBase: UInt64
        let imageSize: UInt32
        let subsystem: UInt16
        let dllCharacteristics: UInt16
    }

    private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset+1]) << 8)
    }
    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) |
        (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
    }
    private func readU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(bytes[offset]) | (UInt64(bytes[offset+1]) << 8) |
        (UInt64(bytes[offset+2]) << 16) | (UInt64(bytes[offset+3]) << 24) |
        (UInt64(bytes[offset+4]) << 32) | (UInt64(bytes[offset+5]) << 40) |
        (UInt64(bytes[offset+6]) << 48) | (UInt64(bytes[offset+7]) << 56)
    }

    private func parsePE(url: URL) -> PEInfo {
        guard let data = try? Data(contentsOf: url),
              let bytes = try? [UInt8](data), bytes.count >= 128 else {
            return PEInfo(machine: "N/A", is64Bit: false, subsystem: "N/A",
                          characteristics: [], sections: 0, timestamp: "",
                          imageSize: 0, entryPoint: 0, linkerVersion: "")
        }

        guard bytes[0] == 0x4D && bytes[1] == 0x5A else {
            return PEInfo(machine: "Not a PE file", is64Bit: false, subsystem: "N/A",
                          characteristics: [], sections: 0, timestamp: "",
                          imageSize: 0, entryPoint: 0, linkerVersion: "")
        }

        let peOffset = Int(readU32(bytes, 0x3C))
        guard peOffset + 24 < bytes.count else {
            return PEInfo(machine: "Invalid header", is64Bit: false, subsystem: "N/A",
                          characteristics: [], sections: 0, timestamp: "",
                          imageSize: 0, entryPoint: 0, linkerVersion: "")
        }

        guard bytes[peOffset] == 0x50 && bytes[peOffset+1] == 0x45 &&
              bytes[peOffset+2] == 0x00 && bytes[peOffset+3] == 0x00 else {
            return PEInfo(machine: "No PE signature", is64Bit: false, subsystem: "N/A",
                          characteristics: [], sections: 0, timestamp: "",
                          imageSize: 0, entryPoint: 0, linkerVersion: "")
        }

        let coff = COFFHeader(
            machine: readU16(bytes, peOffset + 4),
            sections: readU16(bytes, peOffset + 6),
            timestamp: readU32(bytes, peOffset + 8),
            characteristics: readU16(bytes, peOffset + 22)
        )

        let optOffset = peOffset + 24
        let magic = readU16(bytes, optOffset)
        let isPE32Plus = magic == 0x020B
        guard magic == 0x010B || isPE32Plus else {
            return PEInfo(machine: "Unsupported format", is64Bit: isPE32Plus, subsystem: "N/A",
                          characteristics: [], sections: 0, timestamp: "",
                          imageSize: 0, entryPoint: 0, linkerVersion: "")
        }

        let optHdr: OptionalHeader
        if isPE32Plus {
            guard optOffset + 120 < bytes.count else {
                let subsys = readU16(bytes, optOffset + 68)
                return PEInfo(machine: machineName(coff.machine), is64Bit: true,
                              subsystem: subsystemName(subsys),
                              characteristics: parseCharacteristics(coff.characteristics),
                              sections: Int(coff.sections),
                              timestamp: formatTimestamp(coff.timestamp),
                              imageSize: readU32(bytes, optOffset + 56),
                              entryPoint: readU32(bytes, optOffset + 16),
                              linkerVersion: "\(bytes[optOffset + 2]).\(bytes[optOffset + 3])")
            }
            optHdr = OptionalHeader(
                magic: magic,
                linkerMajor: bytes[optOffset + 2],
                linkerMinor: bytes[optOffset + 3],
                addressOfEntryPoint: readU32(bytes, optOffset + 16),
                imageBase: readU64(bytes, optOffset + 24),
                imageSize: readU32(bytes, optOffset + 56),
                subsystem: readU16(bytes, optOffset + 68),
                dllCharacteristics: readU16(bytes, optOffset + 70)
            )
        } else {
            guard optOffset + 96 < bytes.count else {
                let subsys = readU16(bytes, optOffset + 68)
                return PEInfo(machine: machineName(coff.machine), is64Bit: false,
                              subsystem: subsystemName(subsys),
                              characteristics: parseCharacteristics(coff.characteristics),
                              sections: Int(coff.sections),
                              timestamp: formatTimestamp(coff.timestamp),
                              imageSize: readU32(bytes, optOffset + 56),
                              entryPoint: readU32(bytes, optOffset + 16),
                              linkerVersion: "\(bytes[optOffset + 2]).\(bytes[optOffset + 3])")
            }
            optHdr = OptionalHeader(
                magic: magic,
                linkerMajor: bytes[optOffset + 2],
                linkerMinor: bytes[optOffset + 3],
                addressOfEntryPoint: readU32(bytes, optOffset + 16),
                imageBase: UInt64(readU32(bytes, optOffset + 28)),
                imageSize: readU32(bytes, optOffset + 56),
                subsystem: readU16(bytes, optOffset + 68),
                dllCharacteristics: readU16(bytes, optOffset + 70)
            )
        }

        return PEInfo(
            machine: machineName(coff.machine),
            is64Bit: isPE32Plus,
            subsystem: subsystemName(optHdr.subsystem),
            characteristics: parseCharacteristics(coff.characteristics),
            sections: Int(coff.sections),
            timestamp: formatTimestamp(coff.timestamp),
            imageSize: optHdr.imageSize,
            entryPoint: optHdr.addressOfEntryPoint,
            linkerVersion: "\(optHdr.linkerMajor).\(optHdr.linkerMinor)"
        )
    }

    private func machineName(_ m: UInt16) -> String {
        switch m {
        case 0x014C: return "i386 (32-bit)"
        case 0x8664: return "x86-64 (64-bit)"
        case 0x01C4: return "ARMv7 (32-bit)"
        case 0xAA64: return "ARM64 (64-bit)"
        case 0x0200: return "Itanium (64-bit)"
        case 0x01F0: return "ARM Thumb"
        case 0x01C2: return "ARMv5 Thumb"
        case 0x01D3: return "ARMv7 Thumb"
        case 0x5032: return "x86-64 (64-bit)"
        case 0x01C0: return "ARM Little-Endian"
        case 0x00E1: return "MIPS"
        case 0x01F1: return "MIPS16"
        case 0x0266: return "MIPS with FPU"
        case 0x0284: return "Alpha AXP (64-bit)"
        case 0x01A2: return "Hitachi SH3"
        case 0x01A3: return "Hitachi SH3 DSP"
        case 0x01A6: return "Hitachi SH4"
        case 0x01A8: return "Hitachi SH5"
        case 0x01C1: return "Thumb"
        case 0x0184: return "PowerPC Little-Endian"
        case 0x01F2: return "PowerPC with FPU"
        case 0x01BB: return "Cell/PPC (64-bit)"
        case 0x0166: return "MIPS16"
        case 0x01F3: return "MIPS with FPU16"
        case 0x01F4: return "EBC (EFI Byte Code)"
        case 0x00C0: return "RISC-V 32-bit"
        case 0x5064: return "RISC-V 64-bit"
        case 0x5128: return "RISC-V 128-bit"
        case 0x01C6: return "ARM64EC (64-bit)"
        case 0x01C7: return "ARM64X (64-bit)"
        case 0x00A4: return "M32R"
        case 0x00A2: return "SuperH"
        case 0x00A0: return "UNICOS MP"
        default: return "Unknown (0x\(String(m, radix: 16)))"
        }
    }

    private func subsystemName(_ s: UInt16) -> String {
        switch s {
        case 0: return "Unknown"
        case 1: return "Native"
        case 2: return "Windows GUI"
        case 3: return "Windows Console"
        case 5: return "OS/2 Console"
        case 7: return "POSIX Console"
        case 8: return "Native (Windows 9x)"
        case 9: return "Windows CE GUI"
        case 10: return "EFI"
        case 11: return "EFI Boot Driver"
        case 12: return "EFI Runtime Driver"
        case 13: return "EFI ROM Image"
        case 14: return "XBOX"
        case 16: return "Windows Boot Application"
        default: return "Unknown (\(s))"
        }
    }

    private func parseCharacteristics(_ c: UInt16) -> [String] {
        var flags: [String] = []
        if c & 0x0001 != 0 { flags.append("Relocations stripped") }
        if c & 0x0002 != 0 { flags.append("Executable") }
        if c & 0x0004 != 0 { flags.append("Line numbers stripped") }
        if c & 0x0008 != 0 { flags.append("Local symbols stripped") }
        if c & 0x0010 != 0 { flags.append("Aggressive trim") }
        if c & 0x0100 != 0 { flags.append("32-bit") }
        if c & 0x0200 != 0 { flags.append("Debug info stripped") }
        if c & 0x1000 != 0 { flags.append("DLL") }
        if c & 0x2000 != 0 { flags.append("Uniprocessor only") }
        if c & 0x8000 != 0 { flags.append("Big-endian") }
        return flags
    }

    private func formatTimestamp(_ ts: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    // MARK: - HTML Generation

    private func html(info: PEInfo, filename: String) -> String {
        let flagRows = info.characteristics.isEmpty
            ? "<div class=\"entry\"><span class=\"name\">None</span></div>"
            : info.characteristics.map { f in
                "<div class=\"entry\"><span class=\"name\">\(escapeHTML(f))</span></div>"
            }.joined()

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:-apple-system,'SF Mono',Menlo,monospace;font-size:12px;background:#1e1e1e;color:#d4d4d4;padding:16px;overflow-y:auto}
            .header{border-bottom:1px solid #333;padding-bottom:10px;margin-bottom:12px}
            .filename{color:#569cd6;font-size:14px;font-weight:600}
            .summary{color:#808080;font-size:11px;margin-top:4px}
            .section{margin-bottom:12px}
            .section-title{color:#808080;font-size:11px;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px}
            .entry{display:flex;justify-content:space-between;padding:5px 10px;border-bottom:1px solid #2a2a2a}
            .entry:last-child{border-bottom:none}
            .entry .label{color:#808080;min-width:100px;flex-shrink:0}
            .entry .value{color:#d4d4d4;text-align:right;word-break:break-all}
            .entry .value.arch{color:#569cd6;font-weight:600;font-size:13px}
        </style></head>
        <body>
            <div class="header">
                <div class="filename">\(escapeHTML(filename))</div>
                <div class="summary">\(escapeHTML(info.machine))</div>
            </div>
            <div class="section">
                <div class="section-title">Header</div>
                <div class="entry">
                    <span class="label">Subsystem</span>
                    <span class="value">\(escapeHTML(info.subsystem))</span>
                </div>
                <div class="entry">
                    <span class="label">Linker</span>
                    <span class="value">\(escapeHTML(info.linkerVersion))</span>
                </div>
                <div class="entry">
                    <span class="label">Timestamp</span>
                    <span class="value">\(escapeHTML(info.timestamp))</span>
                </div>
                <div class="entry">
                    <span class="label">Sections</span>
                    <span class="value">\(info.sections)</span>
                </div>
            </div>
            <div class="section">
                <div class="section-title">Image</div>
                <div class="entry">
                    <span class="label">Size</span>
                    <span class="value">\(formatSize(info.imageSize))</span>
                </div>
                <div class="entry">
                    <span class="label">Entry Point</span>
                    <span class="value">0x\(String(info.entryPoint, radix: 16).uppercased())</span>
                </div>
            </div>
            <div class="section">
                <div class="section-title">Characteristics</div>
                \(flagRows)
            </div>
        </body>
        </html>
        """
    }

    private func formatSize(_ bytes: UInt32) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
