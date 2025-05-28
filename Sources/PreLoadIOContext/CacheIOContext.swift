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
    let download: DownloadProtocol
    var end = Int64(0)
    /// 当前网络请求的位置
    var urlPos = Int64(0) {
        didSet {
            end = max(end, urlPos)
        }
    }

    /// ffmpeg内部的packet的位置
    public private(set) var logicalPos = Int64(0)
    /// 硬盘缓存文件当前的位置
    var filePos: UInt64 {
        (try? file.offset()) ?? 0
    }

    var maxPhysicalPos: UInt64 {
        entryList.map(\.physicalPos).max() ?? 0
    }

    public internal(set) var entryList = [CacheEntry]()
    let tmpURL: URL
    let file: FileHandle
    var subIOContexts = [CacheIOContext]()
    var isJudgeEOF = true
    private let filePropertyURL: URL
    private let saveFile: Bool
    /// 根据eof判断 end是不是视频的总大小。
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
        let download = try URLContextDownload(url: url, formatContextOptions: formatContextOptions, interrupt: interrupt)
        try self.init(download: download, md5: url.sortQueryString.md5(), saveFile: saveFile)
    }

    public required init(download: DownloadProtocol, md5: String, bufferSize: Int32 = 256 * 1024, saveFile: Bool = false) throws {
        self.saveFile = saveFile
        self.download = download
        var tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
        tmpURL = tmpURL.appendingPathComponent("videoCache")
        if !FileManager.default.fileExists(atPath: tmpURL.path) {
            try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        }
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
        super.init(bufferSize: bufferSize)
//        ffurl_alloc(&context, url.absoluteString, AVIO_FLAG_READ, nil)
//        ffurl_connect(context, options)
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
        if logicalPos != urlPos {
            let result = download.seek(offset: logicalPos, whence: SEEK_SET)
            KSLog("[CacheIOContext] urlPos \(urlPos) ffurl_seek2 \(logicalPos) result \(result)")
            if result < 0 {
                return Int32(result)
            }
            urlPos = result
        }
        var size = size
        if let entry = entryList.first(where: { logicalPos < $0.logicalPos }) {
            let diff = entry.logicalPos - logicalPos
            if diff > 0, diff < size {
                size = Int32(diff)
            }
        }
        // 需要限制下大小。不然size会一直增加的，变得很大
        size = min(size, bufferSize)
        let result = readComplete(buffer: buffer, size: size)
        if result == swift_AVERROR_EOF, size > 0, isJudgeEOF {
            eof = true
        }
        if result <= 0 {
            KSLog("[CacheIOContext] ffurl_read2 fail code:\(result) message: \(String(avErrorCode: result)) urlPos: \(urlPos)")
            return result
        }
        urlPos += Int64(result)
        try? addEntry(logicalPos: logicalPos, buffer: buffer, size: result)
        logicalPos += Int64(result)
        return result
    }

    /// 有的视频开启multiple_requests的话，用ffurl_read_complete启动播放就会失败报错-5，所以自己实现readComplete的逻辑
    private func readComplete(buffer: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        var diff = size
        var buffer = buffer
        repeat {
            let result = download.read(buffer: buffer, size: Int32(diff))
            if result <= 0 {
                // 如果第一次请求就报错的话，那就直接返回错误
                if diff == size {
                    return result
                }
                break
            }
            diff -= result
            buffer = buffer.advanced(by: Int(result))
            // 如果返回的数据太少的话(测试的视频是152)，就不要在继续请求的，不然就会报错-5了。
            // 而且这个是avformat_open_input的时候才会
            if result < 200 {
                break
            }
        } while diff > 0
        return size - diff
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
        if whence == SEEK_SET, offset >= 0, entryList.first(where: { offset >= $0.logicalPos && offset <= $0.logicalPos + Int64($0.size) }) != nil {
            KSLog("[CacheIOContext] urlPos \(urlPos) logicalPos:\(logicalPos) updateTo:\(offset)")
            logicalPos = offset
            return offset
        }
        var diff = offset - urlPos
        // 如果可以read的话，那就不要seek了。因为seek的耗时会更久。
        if whence == SEEK_SET, diff > 0, diff < bufferSize {
            var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(diff))
            var logicalPos = urlPos
            repeat {
                let result = download.read(buffer: buffer, size: Int32(diff))
                if result <= 0 {
                    break
                }
                diff -= Int64(result)
                urlPos += Int64(result)
                try? addEntry(logicalPos: logicalPos, buffer: buffer, size: result)
                logicalPos += Int64(result)
            } while diff > 0
            buffer.deallocate()
            if logicalPos == offset {
                self.logicalPos = logicalPos
                KSLog("[CacheIOContext] read to \(offset)")
                return offset
            }
        }
        var result = download.seek(offset: offset, whence: whence)
        KSLog("[CacheIOContext] urlPos \(urlPos) ffurl_seek2 \(offset) result \(result)")
        if result < 0 {
            // 第一次seek失败的话，那就在尝试一下可能就成功
            result = download.seek(offset: offset, whence: whence)
            KSLog("[CacheIOContext] urlPos \(urlPos) ffurl_seek2 \(offset) result \(result)")
        }
        if result >= 0 {
            logicalPos = result
            urlPos = result
        } else {}
        return result
    }

    override public func fileSize() -> Int64 {
        if eof {
            return end
        }
        var pos = download.fileSize()
        KSLog("[CacheIOContext] ffurl_seek2 \(pos)")
        if pos <= 0 {
            pos = download.seek(offset: -1, whence: SEEK_END)
            if pos < 0 {
                KSLog("[CacheIOContext] Inner protocol failed to seekback end")
            }
        }
        end = max(end, pos)
        if pos > 0 {
            // 这里不能设置logicalPos和urlPos 不然smb播放就会有问题
            if isJudgeEOF {
                eof = true
                /// 有的直播回放ts流,在一开始播放的时候，会重复播放前面10s。
                /// 看了下好像是因为在得到文件总大小之前缓存的数据是有问题的。
                /// 所以这边先把之前的数据给清空了。
                entryList.removeAll()
            }
        }
        // 为了解决ts seek的问题。 ts使用AVSEEK_FLAG_BYTE。所以需要返回文件大小，这样才能seek。
        return end
    }

    override public func close() {
        try? file.close()
        download.close()
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

    /// 判断当前的片段是否会超过下一个硬盘片段
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

    override open func addSub(url: URL, flags: Int32, options: UnsafeMutablePointer<OpaquePointer?>?, interrupt: AVIOInterruptCB) -> UnsafeMutablePointer<AVIOContext>? {
        // url一样的话也不要进行复用。每次都要new一个新的。
        if let download = try? URLContextDownload(url: url, flags: flags, options: options, interrupt: interrupt), let subIOContext = try? Self(download: download, md5: url.sortQueryString.md5(), bufferSize: bufferSize, saveFile: saveFile) {
            subIOContexts.append(subIOContext)
            subIOContext.isJudgeEOF = false
            return download.getURLContext(ioContext: self)
        } else {
            return nil
        }
    }
}

extension CacheIOContext: PlayList {
    public var audioLanguageCodeMap: [Int32: String] {
        (download as? PlayList)?.audioLanguageCodeMap ?? [:]
    }

    public var subtitleLanguageCodeMap: [Int32: String] {
        (download as? PlayList)?.subtitleLanguageCodeMap ?? [:]
    }

    public var playlists: [MovieStream] {
        (download as? PlayList)?.playlists ?? []
    }

    public var currentStream: MovieStream? {
        (download as? PlayList)?.currentStream
    }
}

public class URLContextDownload: DownloadProtocol {
    var context: UnsafeMutablePointer<URLContext>? = nil
    private let keepAlive: Bool
    public convenience init(url: URL, formatContextOptions: [String: Any], interrupt: AVIOInterruptCB) throws {
        var avOptions = formatContextOptions.avOptions
        try self.init(url: url, flags: AVIO_FLAG_READ, options: &avOptions, interrupt: interrupt)
        av_dict_free(&avOptions)
    }

    public init(url: URL, flags: Int32, options: UnsafeMutablePointer<OpaquePointer?>?, interrupt: AVIOInterruptCB) throws {
        var interruptCB = interrupt
        if let value = av_dict_get(options?.pointee, "multiple_requests", nil, 0), String(cString: value.pointee.value) == "1" {
            keepAlive = true
        } else {
            keepAlive = false
        }
        let result = ffurl_open_whitelist(&context, url.absoluteString, flags, &interruptCB, options, nil, nil, nil)

        //        ffurl_alloc(&context, url.absoluteString, AVIO_FLAG_READ, nil)
        //        ffurl_connect(context, options)
        if result != 0 {
            throw KSPlayerError(errorCode: .formatOpenInput, avErrorCode: result)
        }
    }

    public func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let context else {
            return swift_AVERROR_EOF
        }
        return ffurl_read2(context, buffer, size)
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        guard let context else {
            return -1
        }
        return ffurl_seek2(context, offset, whence)
    }

    public func fileSize() -> Int64 {
        guard let context else {
            return -1
        }
        return seek(offset: 0, whence: AVSEEK_SIZE)
    }

    public func close() {
        ffurl_closep(&context)
    }

    func getURLContext(ioContext: AbstractAVIOContext) -> UnsafeMutablePointer<AVIOContext>? {
        guard let context else {
            return nil
        }
        context.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(ioContext).toOpaque()
        let pb = avio_alloc_context(av_malloc(Int(ioContext.bufferSize)), ioContext.bufferSize, 0, context) { opaque, buffer, size -> Int32 in
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

public extension URL {
    /// 返回一个具有规范化参数顺序的新 URL 字符串
    var sortQueryString: String {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            return absoluteString
        }
        let sortedQuery = queryItems.sorted { $0.name < $1.name }
        var normalizedComponents = components
        normalizedComponents.queryItems = sortedQuery
        return normalizedComponents.url?.absoluteString ?? absoluteString
    }
}
