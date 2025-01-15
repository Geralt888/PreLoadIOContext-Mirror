//
//  CacheIOContext.swift
//
//
//  Created by kintan on 3/22/24.
//

import FFmpegKit
import Foundation
import KSPlayer
import Libavformat

public class CacheIOContext: AbstractAVIOContext {
    class CacheEntry: Codable {
        private static let maxEntrySize = 8 * 1024 * 1024
        let logicalPos: Int64
        let physicalPos: UInt64
        var size: UInt64
        var eof: Bool = false
        var maxSize: UInt64?
        init(logicalPos: Int64, physicalPos: UInt64, size: UInt64, maxSize: UInt64? = nil) {
            self.logicalPos = logicalPos
            self.physicalPos = physicalPos
            self.size = size
            self.maxSize = maxSize
        }

        func isOut(size: UInt64) -> Bool {
            if self.size > CacheIOContext.CacheEntry.maxEntrySize {
                true
            } else if let maxSize, self.size + size > maxSize {
                true
            } else {
                false
            }
        }
    }

    var context: UnsafeMutablePointer<URLContext>? = nil
    var end = Int64(0)
    // 网络请求也就是url的位置
    var urlPos = Int64(0) {
        didSet {
            end = max(end, urlPos)
        }
    }

    // ffmpeg内部的packet的位置
    var logicalPos = Int64(0)
    // 缓存文件当前的位置
    var filePos: UInt64 {
        (try? file.offset()) ?? 0
    }

    var maxPhysicalPos: UInt64 {
        entryList.map(\.physicalPos).max() ?? 0
    }

    var entryList = [CacheEntry]()
    let tmpURL: URL
    let file: FileHandle
    var subIOContexts = [CacheIOContext]()
    var isJudgeEOF = true
    private let filePropertyURL: URL
    private let saveFile: Bool
    private let url: URL
    // end是不是视频的总大小。
    var eof = false {
        didSet {
            if eof {
                for entry in entryList {
                    entry.eof = entry.logicalPos + Int64(entry.size) == end
                }
            }
        }
    }

    public required convenience init(url: URL, formatContextOptions: [String: Any], interrupt: AVIOInterruptCB, saveFile: Bool = false) throws {
        var avOptions = formatContextOptions.avOptions
        try self.init(url: url, flags: AVIO_FLAG_READ, options: &avOptions, interrupt: interrupt, saveFile: saveFile)
        av_dict_free(&avOptions)
    }

    required init(url: URL, flags: Int32, options: UnsafeMutablePointer<OpaquePointer?>?, interrupt: AVIOInterruptCB, saveFile: Bool) throws {
        self.url = url
        self.saveFile = saveFile
        var tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
        tmpURL = tmpURL.appendingPathComponent("videoCache")
        if !FileManager.default.fileExists(atPath: tmpURL.path) {
            try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        }
        let md5 = url.path.md5()
        filePropertyURL = tmpURL.appendingPathComponent(md5 + ".plist")
        tmpURL = tmpURL.appendingPathComponent(md5)
        if !saveFile {
            try? FileManager.default.removeItem(at: tmpURL)
            try? FileManager.default.removeItem(at: filePropertyURL)
        }
        if !FileManager.default.fileExists(atPath: tmpURL.path) {
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        }
        file = try FileHandle(forUpdating: tmpURL)
        self.tmpURL = tmpURL
        if FileManager.default.fileExists(atPath: filePropertyURL.path), let data = FileManager.default.contents(atPath: filePropertyURL.path) {
            if let list = try? PropertyListDecoder().decode([CacheEntry].self, from: data) {
                entryList = list
                if let entry = entryList.first(where: { $0.eof }) {
                    end = entry.logicalPos + Int64(entry.size)
                    eof = true
                }
            }
        }
        super.init()
        var interruptCB = interrupt
        let result = ffurl_open_whitelist(&context, url.absoluteString, flags, &interruptCB, options, nil, nil, nil)
//        ffurl_alloc(&context, url.absoluteString, AVIO_FLAG_READ, nil)
//        ffurl_connect(context, options)
        if result != 0, entryList.isEmpty {
            throw NSError(errorCode: .formatOpenInput, avErrorCode: result)
        }
    }

    override public func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer else {
            return 0
        }
        if logicalPos == end, eof {
            return swift_AVERROR_EOF
        } else if let entry = entryList.first(where: { logicalPos >= $0.logicalPos && logicalPos < $0.logicalPos + Int64($0.size) }) {
            let inBlockPos = logicalPos - entry.logicalPos
            let physicalTarget = entry.physicalPos + UInt64(inBlockPos)
            if filePos != physicalTarget {
                try? file.seek(toOffset: physicalTarget)
            }
            let result: Int32
            if let data = try? file.read(upToCount: min(Int(size), Int(entry.size) - Int(inBlockPos))) {
                data.copyBytes(to: buffer, count: data.count)
                result = Int32(data.count)
            } else {
                result = -1
            }
            if result > 0 {
                logicalPos += Int64(result)
                return result
            }
        }
        guard let context else {
            return swift_AVERROR_EOF
        }
        if logicalPos != urlPos {
            let result = ffurl_seek2(context, logicalPos, SEEK_SET)
            KSLog("[CacheIOContext] read ffurl_seek2 \(logicalPos) result \(result)")
            if result < 0 {
                return Int32(result)
            }
            urlPos = result
        }
        var size = size
        if let entry = entryList.first(where: { logicalPos < $0.logicalPos }) {
            let diff = entry.logicalPos - urlPos
            if diff > 0, diff < size {
                size = Int32(diff)
            }
        }
        let result = ffurl_read2(context, buffer, size)
        if result == swift_AVERROR_EOF, size > 0, isJudgeEOF {
            eof = true
        }
        if result <= 0 {
            KSLog("[CacheIOContext] read ffurl_read2 fail code:\(result) message: \(String(avErrorCode: result)) urlPos: \(urlPos)")
            return result
        }
        urlPos += Int64(result)
        try? addEntry(logicalPos: logicalPos, buffer: buffer, size: result)
        logicalPos += Int64(result)
        return result
    }

    override public func seek(offset: Int64, whence: Int32) -> Int64 {
        var offset = offset
        var whence = whence
        if whence == SEEK_CUR {
            whence = SEEK_SET
            offset += logicalPos
        } else if whence == SEEK_END, eof {
            whence = SEEK_SET
            offset += end
        }
        if whence == SEEK_SET, offset >= 0, entryList.first(where: { offset >= $0.logicalPos && offset < $0.logicalPos + Int64($0.size) }) != nil {
            logicalPos = offset
            return offset
        }
        guard let context else {
            return -1
        }
        let result = ffurl_seek2(context, offset, whence)
        KSLog("[CacheIOContext] seek ffurl_seek2 \(offset) result \(result)")
        if result >= 0 {
            logicalPos = result
            urlPos = result
        }
        return result
    }

    override public func fileSize() -> Int64 {
        if eof {
            return end
        }
        guard let context else {
            return -1
        }
        var pos = ffurl_seek2(context, 0, AVSEEK_SIZE)
        KSLog("[CacheIOContext] fileSize ffurl_seek2 \(pos)")
        if pos <= 0 {
            pos = ffurl_seek2(context, -1, SEEK_END)
            if ffurl_seek2(context, urlPos, SEEK_SET) < 0 {
                KSLog("[CacheIOContext] Inner protocol failed to seekback end")
            }
        }
        end = max(end, pos)
        if pos > 0, isJudgeEOF {
            eof = true
        }
        // 为了解决ts seek的问题。 ts使用AVSEEK_FLAG_BYTE。所以需要返回文件大小，这样才能seek。
        if pos < 0 || url.pathExtension == "ts" {
            return end
        } else {
            return pos
        }
    }

    override public func close() {
        try? file.close()
        ffurl_closep(&context)
        if saveFile {
            // 为了触发eof的didSet方法，更新entry中的eof字段
            if eof {
                eof = true
            }
            save()
        } else {
            try? FileManager.default.removeItem(at: tmpURL)
            try? FileManager.default.removeItem(at: filePropertyURL)
        }
    }

    override open func addSub(url: URL, flags: Int32, options: UnsafeMutablePointer<OpaquePointer?>?, interrupt: AVIOInterruptCB) -> UnsafeMutablePointer<AVIOContext>? {
        // url一样的话也不要进行复用。每次都要new一个新的。
        if let subIOContext = try? Self(url: url, flags: flags, options: options, interrupt: interrupt, saveFile: saveFile) {
            subIOContexts.append(subIOContext)
            subIOContext.isJudgeEOF = false
            return subIOContext.getURLContext()
        } else {
            return nil
        }
    }

    func addEntry(logicalPos: Int64, buffer: UnsafeMutablePointer<UInt8>, size: Int32) throws {
        let entry = entryList.first(where: { logicalPos == $0.logicalPos + Int64($0.size) })
        if let entry, !entry.isOut(size: UInt64(size)), !isOut(entry: entry, size: UInt64(size)) {
            try add(entry: entry, buffer: buffer, size: size)
        } else {
            if let entry, entry.maxSize == nil {
                entry.maxSize = entry.size
            }
            let physicalPos = try file.seekToEnd()
            try file.write(contentsOf: Data(bytes: buffer, count: Int(size)))
            let entry = CacheEntry(logicalPos: logicalPos, physicalPos: physicalPos, size: UInt64(size))
            entryList.append(entry)
            entryList.sort { left, right in
                left.logicalPos < right.logicalPos
            }
            save()
        }
    }

    // 判断当前的片段是否会超过下一个硬盘片段
    private func isOut(entry: CacheEntry, size: UInt64) -> Bool {
        let first = entryList.first { element in
            entry.physicalPos < element.physicalPos && entry.physicalPos + entry.size + size > element.physicalPos
        }
        if let first {
            if entry.maxSize == nil {
                entry.maxSize = first.physicalPos - entry.physicalPos
            }
            return true
        } else {
            return false
        }
    }

    func add(entry: CacheEntry, buffer: UnsafeMutablePointer<UInt8>, size: Int32) throws {
        let physicalPos = entry.physicalPos + entry.size
        if filePos != physicalPos {
            try file.seek(toOffset: physicalPos)
        }
        try file.write(contentsOf: Data(bytes: buffer, count: Int(size)))
        entry.size += UInt64(size)
    }

    func save() {
        if saveFile {
            let data = try? PropertyListEncoder().encode(entryList)
            try? data?.write(to: filePropertyURL)
        }
    }
}

extension CacheIOContext {
    func getURLContext() -> UnsafeMutablePointer<AVIOContext>? {
        guard let context else {
            return nil
        }
        context.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        let pb = avio_alloc_context(av_malloc(Int(AbstractAVIOContext.bufferSize)), AbstractAVIOContext.bufferSize, 0, context) { opaque, buffer, size -> Int32 in
            guard let context = opaque?.assumingMemoryBound(to: URLContext.self), let opaque = context.pointee.interrupt_callback.opaque else {
                return -1
            }
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque).takeUnretainedValue()
            let ret = value.read(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, buffer, size -> Int32 in
            guard let context = opaque?.assumingMemoryBound(to: URLContext.self), let opaque = context.pointee.interrupt_callback.opaque else {
                return -1
            }
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque).takeUnretainedValue()
            let ret = value.write(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, offset, whence -> Int64 in
            guard let context = opaque?.assumingMemoryBound(to: URLContext.self), let opaque = context.pointee.interrupt_callback.opaque else {
                return -1
            }
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque).takeUnretainedValue()
            if whence == AVSEEK_SIZE {
                return value.fileSize()
            }
            return value.seek(offset: offset, whence: whence)
        }
        return pb
    }
}
