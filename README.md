```Swift
import KSPlayer
import Libavformat
class MEOptions: KSOptions {

 override func process(url: URL, interrupt: AVIOInterruptCB) -> AbstractAVIOContext? {
   if url.pathExtension == "m3u8" || url.pathExtension == "hls" {
      return nil
   }
   if !url.isFileURL, let context = try? LimitPreLoadIOContext(url: url, formatContextOptions: formatContextOptions, interrupt: interrupt) {
      return context
   }
  return nil
 }
}
```
