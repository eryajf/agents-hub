import CryptoKit
import Foundation

struct AsarReplacement: Sendable, Hashable {
    var path: String
    var search: String
    var replacement: String
}

enum ElectronAsarError: LocalizedError, Equatable {
    case invalidArchive
    case missingFile(String)
    case replacementLengthMismatch(String)
    case replacementSearchNotFound(String)
    case replacementSearchAmbiguous(String)
    case headerSizeChanged
    case invalidFileRange(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "Invalid Electron asar archive."
        case let .missingFile(path):
            "Asar file not found: \(path)"
        case let .replacementLengthMismatch(path):
            "Replacement must keep the same byte length for \(path)."
        case let .replacementSearchNotFound(path):
            "Patch marker not found in \(path)."
        case let .replacementSearchAmbiguous(path):
            "Patch marker matched more than once in \(path)."
        case .headerSizeChanged:
            "Asar header size changed unexpectedly."
        case let .invalidFileRange(path):
            "Asar file range is invalid: \(path)"
        }
    }
}

struct ElectronAsarArchive: Sendable {
    let url: URL

    func string(at path: String) throws -> String {
        let data = try Data(contentsOf: url)
        let parsed = try ParsedAsar(data: data)
        let entry = try parsed.entry(at: path)
        let fileData = try parsed.fileData(for: entry)
        return String(decoding: fileData, as: UTF8.self)
    }

    func integrityHash(at path: String) throws -> String? {
        let data = try Data(contentsOf: url)
        let parsed = try ParsedAsar(data: data)
        let entry = try parsed.entry(at: path)
        return entry.integrityHash
    }

    func headerSHA256Hex() throws -> String {
        let data = try Data(contentsOf: url)
        let parsed = try ParsedAsar(data: data)
        return Self.sha256Hex(parsed.headerData)
    }

    func contains(path: String) throws -> Bool {
        let data = try Data(contentsOf: url)
        let parsed = try ParsedAsar(data: data)
        return parsed.hasEntry(at: path)
    }

    func apply(_ replacements: [AsarReplacement]) throws {
        guard !replacements.isEmpty else { return }

        var data = try Data(contentsOf: url)
        var parsed = try ParsedAsar(data: data)
        var header = parsed.headerString

        for replacement in replacements {
            guard replacement.search.utf8.count == replacement.replacement.utf8.count else {
                throw ElectronAsarError.replacementLengthMismatch(replacement.path)
            }

            let entry = try parsed.entry(at: replacement.path)
            var content = try parsed.fileData(for: entry)
            let searchData = Data(replacement.search.utf8)
            let replacementData = Data(replacement.replacement.utf8)
            let ranges = content.ranges(of: searchData)

            guard !ranges.isEmpty else {
                throw ElectronAsarError.replacementSearchNotFound(replacement.path)
            }
            guard ranges.count == 1 else {
                throw ElectronAsarError.replacementSearchAmbiguous(replacement.path)
            }

            content.replaceSubrange(ranges[0], with: replacementData)

            let fileRange = try parsed.fileRangeChecked(for: entry)
            data.replaceSubrange(fileRange, with: content)

            let newFileHash = Self.sha256Hex(content)
            if let oldFileHash = entry.integrityHash {
                header = header.replacingOccurrences(of: oldFileHash, with: newFileHash)
            }

            let blockSize = entry.blockSize ?? content.count
            let oldBlocks = entry.blockHashes
            let newBlocks = Self.blockHashes(for: content, blockSize: blockSize)
            for (oldBlock, newBlock) in zip(oldBlocks, newBlocks) {
                header = header.replacingOccurrences(of: oldBlock, with: newBlock)
            }

            let headerData = Data(header.utf8)
            guard headerData.count == parsed.jsonSize else {
                throw ElectronAsarError.headerSizeChanged
            }
            data.replaceSubrange(parsed.jsonRange, with: headerData)
            parsed = try ParsedAsar(data: data)
        }

        try data.write(to: url, options: .atomic)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func blockHashes(for data: Data, blockSize: Int) -> [String] {
        guard blockSize > 0 else { return [sha256Hex(data)] }
        var hashes: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + blockSize, data.count)
            hashes.append(sha256Hex(data.subdata(in: offset..<end)))
            offset = end
        }
        if data.isEmpty {
            hashes.append(sha256Hex(data))
        }
        return hashes
    }
}

private struct ParsedAsar {
    let data: Data
    let headerSize: Int
    let jsonSize: Int
    let headerData: Data
    let headerString: String
    let headerObject: [String: Any]

    init(data: Data) throws {
        guard data.count >= 16 else { throw ElectronAsarError.invalidArchive }
        self.data = data

        let headerSize = Int(data.readUInt32LE(at: 4))
        let jsonSize = Int(data.readUInt32LE(at: 12))
        guard headerSize >= jsonSize + 8,
              data.count >= 16 + jsonSize
        else {
            throw ElectronAsarError.invalidArchive
        }

        self.headerSize = headerSize
        self.jsonSize = jsonSize

        let headerData = data.subdata(in: 16..<(16 + jsonSize))
        guard let headerString = String(data: headerData, encoding: .utf8),
              let headerObject = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else {
            throw ElectronAsarError.invalidArchive
        }

        self.headerData = headerData
        self.headerString = headerString
        self.headerObject = headerObject
    }

    var contentStart: Int {
        8 + headerSize
    }

    var jsonRange: Range<Data.Index> {
        16..<(16 + jsonSize)
    }

    func hasEntry(at path: String) -> Bool {
        (try? entry(at: path)) != nil
    }

    func entry(at path: String) throws -> AsarEntry {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw ElectronAsarError.missingFile(path) }

        var node = headerObject
        for component in components {
            guard let files = node["files"] as? [String: Any],
                  let child = files[component] as? [String: Any]
            else {
                throw ElectronAsarError.missingFile(path)
            }
            node = child
        }

        guard let size = node["size"] as? Int,
              let offsetString = node["offset"] as? String,
              let offset = Int(offsetString)
        else {
            throw ElectronAsarError.missingFile(path)
        }

        let integrity = node["integrity"] as? [String: Any]
        return AsarEntry(
            path: path,
            size: size,
            offset: offset,
            integrityHash: integrity?["hash"] as? String,
            blockSize: integrity?["blockSize"] as? Int,
            blockHashes: integrity?["blocks"] as? [String] ?? []
        )
    }

    func fileRangeChecked(for entry: AsarEntry) throws -> Range<Data.Index> {
        let start = contentStart + entry.offset
        let end = start + entry.size
        guard start >= data.startIndex, end <= data.endIndex, start <= end else {
            throw ElectronAsarError.invalidFileRange(entry.path)
        }
        return start..<end
    }

    func fileData(for entry: AsarEntry) throws -> Data {
        try data.subdata(in: fileRangeChecked(for: entry))
    }
}

private struct AsarEntry {
    var path: String
    var size: Int
    var offset: Int
    var integrityHash: String?
    var blockSize: Int?
    var blockHashes: [String]
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func ranges(of needle: Data) -> [Range<Data.Index>] {
        guard !needle.isEmpty, count >= needle.count else { return [] }

        var result: [Range<Data.Index>] = []
        var searchStart = startIndex
        while searchStart <= endIndex - needle.count {
            guard let range = self[searchStart...].range(of: needle) else { break }
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }
}
