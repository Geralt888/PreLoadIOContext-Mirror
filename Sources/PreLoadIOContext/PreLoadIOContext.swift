//
//  PreLoadIOContext.swift
//
//
//  Created by kintan on 3/22/24.
//

import FFmpegKit
import Foundation
import KSPlayer
import Libavformat

/// 无限制的缓存看过的内容，并加载更多数据，
public class PreLoadIOContext: CacheIOContext, PreLoadProtocol {
    var loadMoreBuffer: UnsafeMutablePointer<UInt8>?
    /// 这个是假的UrlPos，只是为了用来计算缓存进度。
    private var fakeUrlPos = Int64(0)
    override public var urlPos: Int64 {
        didSet {
            fakeUrlPos = urlPos
        }
    }

    override public func close() {
        if let loadMoreBuffer {
            loadMoreBuffer.deallocate()
            self.loadMoreBuffer = nil
        }
        super.close()
    }

    public var loadedSize: Int64 {
        fakeUrlPos - logicalPos
    }

    override public func seek(offset: Int64, whence: Int32) -> Int64 {
        // 先让缓存进度变为0
        fakeUrlPos = logicalPos
        let result = super.seek(offset: offset, whence: whence)
        if result > 0, logicalPos != urlPos {
            /// 需要马上更新下fakeUrlPos的位置。这样缓存进度才能及时更新。
            /// 但是不能进行seek。这样才不会有缓冲。等到真正需要的时候在seek
            if let pos = findURLPos() {
                fakeUrlPos = pos
            } else {
                fakeUrlPos = urlPos
            }
        }
        return result
    }

    /// 找到从logicalPos开始的，第一个不连续的片段。如果有的话，就返回那个位置
    func findURLPos() -> Int64? {
        guard var index = entryList.firstIndex(where: { logicalPos >= $0.logicalPos && logicalPos < $0.logicalPos + Int64($0.size) }) else {
            return nil
        }
        var entry = entryList[index]
        var pos = entry.logicalPos + Int64(entry.size)
        index += 1
        while index < entryList.count {
            let newEntry = entryList[index]
            if pos == newEntry.logicalPos {
                entry = newEntry
                pos = entry.logicalPos + Int64(entry.size)
                index += 1
            } else {
                break
            }
        }
        if urlPos == pos {
            return nil
        } else {
            return pos
        }
    }

    public func more() -> Int32 {
        if loadMoreBuffer == nil {
            loadMoreBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize))
        }
        guard let loadMoreBuffer else {
            return -1
        }
        // 如果已经加载的的话，那就不在加载了,但是需要定位到那个位置，并更新urlPos
        if let pos = findURLPos() {
            let result = download.seek(offset: pos, whence: SEEK_SET)
            KSLog("[CacheIOContext] more ffurl_seek2 \(pos)")
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
        let result = download.read(buffer: loadMoreBuffer, size: size)
        if result == swift_AVERROR_EOF, size > 0, isJudgeEOF {
            eof = true
        }
        if result <= 0 {
            return result
        }
        try? addEntry(logicalPos: urlPos, buffer: loadMoreBuffer, size: result)
        urlPos += Int64(result)
        return result
    }
}
