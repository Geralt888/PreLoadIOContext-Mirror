//
//  LimitPreLoadIOContext.swift
//
//
//  Created by kintan on 3/22/24.
//

import FFmpegKit
import Foundation
import KSPlayer
import Libavformat
import QuartzCore

/// 有大小限制的缓存看过的内容并加载更多的
public class LimitPreLoadIOContext: PreLoadIOContext {
    private let maxFileSize: UInt64
    /// 当缓存空间上限时，已看过要缓存的最小字节
    private let minReadedFileSize: UInt64
    /// maxFileSize 不要太小。不然就会缓存失效。特别是高码率的视频。
    public init(download: DownloadProtocol, md5: String, bufferSize: Int32 = 256 * 1024, saveFile: Bool = false, maxFileSize: UInt64, minReadedFileSize: UInt64) throws {
        self.maxFileSize = maxFileSize
        self.minReadedFileSize = minReadedFileSize
        try super.init(download: download, md5: md5, bufferSize: bufferSize, saveFile: saveFile)
    }

    public required convenience init(download: DownloadProtocol, md5: String, bufferSize: Int32 = 256 * 1024, saveFile: Bool = false) throws {
        try self.init(download: download, md5: md5, bufferSize: bufferSize, saveFile: saveFile, maxFileSize: 1024 * 1024 * 1024, minReadedFileSize: 128 * 1024 * 1024)
    }

    override public func more() -> Int32 {
        if loadMoreBuffer == nil {
            loadMoreBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize))
        }
        guard let loadMoreBuffer else {
            return -1
        }
        // 如果已经加载的的话，那就不在加载了,但是需要定位到那个位置，并更新urlPos
        if let pos = findURLPos() {
            let result = download.seek(offset: pos, whence: SEEK_SET)
            KSLog("[CacheIOContext] more ffurl_seek2 \(pos) result: \(result)")
            if result >= 0 {
                urlPos = result
            }
            return 1
        }
        if eof, urlPos == end {
            return -1
        }
        var size = bufferSize
        if let entry = entryList.first(where: { urlPos < $0.logicalPos + Int64($0.size) }) {
            let diff = entry.logicalPos - urlPos
            if diff > 0 {
                size = Int32(min(Int64(size), diff))
            }
        }
        let newEntry: CacheEntry?
        // 先看下还有没有片段有空间的，有的话，先塞满。
        if let entry = entryList.first(where: { urlPos == $0.logicalPos + Int64($0.size) }), !entry.isOut(size: UInt64(size)) {
            // 复用的entry有大小限制，所以要当entry还有容量的时候，要取最小值，不然就会有空洞
            if let maxSize = entry.maxSize, maxSize > entry.size {
                size = min(size, Int32(maxSize - entry.size))
            }
            newEntry = nil
        } else if entryList.map(\.size).reduce(0, +) > maxFileSize {
            // 超出大小限制，那就看下是否有看过的完整片段
            if entryList[0].logicalPos + Int64(entryList[0].size + minReadedFileSize) < logicalPos {
                let entry = entryList.removeFirst()
                KSLog("[CacheIOContext] remove first entryLogicalPos:\(entry.logicalPos), logicalPos:\(logicalPos)")
                newEntry = CacheEntry(logicalPos: urlPos, physicalPos: entry.physicalPos, size: 0, maxSize: entry.maxSize ?? entry.size)
                size = min(size, Int32(entry.size))
            } else if let last = entryList.last, last.logicalPos > urlPos {
                let entry = entryList.removeLast()
                newEntry = CacheEntry(logicalPos: urlPos, physicalPos: entry.physicalPos, size: 0, maxSize: entry.maxSize ?? entry.size)
                size = min(size, Int32(entry.size))
            } else {
                KSLog("[CacheIOContext] reach maxFileSize:\(maxFileSize) first entryLogicalPos:\(entryList.first?.logicalPos) last entryLogicalPos:\(entryList.last?.logicalPos) logicalPos:\(logicalPos)")
                return 0
            }
        } else {
            newEntry = nil
        }
        let start = CACurrentMediaTime()
        let result = readComplete(buffer: loadMoreBuffer, size: size)
        if result == swift_AVERROR_EOF, size > 0, isJudgeEOF {
            eof = true
        }
        if result <= 0 {
            KSLog("[CacheIOContext] more ffurl_read2 fail code:\(result) message: \(String(avErrorCode: result)) costTime: \(CACurrentMediaTime() - start)")
            return result
        }
        if let newEntry {
            try? add(entry: newEntry, buffer: loadMoreBuffer, size: result)
            entryList.append(newEntry)
            entryList.sort { left, right in
                left.logicalPos < right.logicalPos
            }
            save()
        } else {
            try? addEntry(logicalPos: urlPos, buffer: loadMoreBuffer, size: result)
        }
        urlPos += Int64(result)
        return result
    }
}
