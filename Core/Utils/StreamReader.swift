
import Foundation

class StreamReader {
    let encoding: String.Encoding
    let chunkSize: Int
    var fileHandle: FileHandle!
    let delimData: Data
    var buffer: Data
    var atEof: Bool

    init?(path: String, delimiter: String = "\n", encoding: String.Encoding = .utf8, chunkSize: Int = 4096) {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
        self.encoding = encoding
        self.buffer = Data(capacity: chunkSize)
        self.atEof = false
        self.delimData = delimiter.data(using: encoding)!
    }

    deinit {
        self.close()
    }

    func nextLine() -> String? {
        precondition(fileHandle != nil, "Attempt to read from closed file")

        while !atEof {
            if let range = buffer.range(of: delimData) {
                let line = String(data: buffer.subdata(in: 0..<range.lowerBound), encoding: encoding)
                buffer.removeSubrange(0..<range.upperBound)
                return line
            }
            let tmpData = fileHandle.readData(ofLength: chunkSize)
            if tmpData.count > 0 {
                buffer.append(tmpData)
            } else {
                atEof = true
                if buffer.count > 0 {
                    let line = String(data: buffer as Data, encoding: encoding)
                    buffer.count = 0
                    return line
                }
            }
        }
        return nil
    }

    func close() {
        fileHandle?.closeFile()
        fileHandle = nil
    }
}

extension StreamReader: Sequence {
    func makeIterator() -> AnyIterator<String> {
        return AnyIterator { return self.nextLine() }
    }
}
