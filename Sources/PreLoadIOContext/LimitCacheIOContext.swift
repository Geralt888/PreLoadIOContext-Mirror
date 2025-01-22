//
//  LimitCacheIOContext.swift
//
//
//  Created by kintan on 3/22/24.
//

import FFmpegKit
import Foundation
import KSPlayer
import Libavformat

// 有大小限制的缓存看过的内容
public class LimitCacheIOContext: CacheIOContext {
    private let maxFileSize: UInt64
    // maxFileSize 不要太小。不然就会缓存失效。特别是高码率的视频。
    public required init(download: DownloadProtocol, md5: String, saveFile: Bool, maxFileSize: UInt64) throws {
        self.maxFileSize = maxFileSize
        try super.init(download: download, md5: md5, saveFile: saveFile)
    }

    public required convenience init(download: DownloadProtocol, md5: String, saveFile: Bool = false) throws {
        try self.init(download: download, md5: md5, saveFile: saveFile, maxFileSize: 1024 * 1024 * 1024)
    }

    override func addEntry(logicalPos: Int64, buffer: UnsafeMutablePointer<UInt8>, size: Int32) throws {
        let entry = entryList.first(where: { logicalPos == $0.logicalPos + Int64($0.size) })
        let physicalPos: UInt64
        if let entry, entry.physicalPos == maxPhysicalPos, !entry.isOut(size: UInt64(size)) {
            try add(entry: entry, buffer: buffer, size: size)
        } else {
            let maxSize: UInt64?
            // 超出文件限制大小的处理
            if let last = entryList.last, last.maxSize != nil || last.physicalPos + last.size > maxFileSize {
                let first = entryList.removeFirst()
                physicalPos = first.physicalPos
                if filePos != physicalPos {
                    try file.seek(toOffset: physicalPos)
                }
                // 如果一个分块太小的话，那就合并下一个分块，防止seek造成有很小的分块。
                let firstSize = first.maxSize ?? first.size
                if firstSize < size {
                    let second = entryList.removeFirst()
                    maxSize = firstSize + (second.maxSize ?? second.size)
                } else {
                    maxSize = firstSize
                }
            } else {
                physicalPos = try file.seekToEnd()
                maxSize = nil
            }
            try file.write(contentsOf: Data(bytes: buffer, count: Int(size)))
            let entry = CacheEntry(logicalPos: logicalPos, physicalPos: physicalPos, size: UInt64(size), maxSize: maxSize)
            entryList.append(entry)
            entryList.sort { left, right in
                left.logicalPos < right.logicalPos
            }
            save()
        }
    }
}
