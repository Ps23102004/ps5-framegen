// The in-app luma sampler run on a recorded file (no capture device needed): diff trace + cost per frame.
// Build: xcrun swiftc -O -swift-version 5 probes/luma_mad.swift -o probes/luma_mad
//        (4 deprecation warnings for the old AVAssetReader calls on the macOS 27 SDK; the probe still runs)
// Run:   probes/luma_mad <video> <start s> <seconds> <out.csv> [maskX 0..1] [maskY 0..1] [outW outH]
//        outW outH (e.g. 1920 1080) makes the decoder scale, so the cost matches the live 1080p buffer size.
// Decodes to 420v, reads every 4th pixel of every 32nd row of the Y plane straight from the locked
// base address (the grid in skills/capture-cadence/SKILL.md), and writes one CSV row per frame:
// frame,pts_s,diff,diff_full,cost_us
// (same first three columns as cadence_trace.py, so `cadence_trace.py stats <csv>` reads it).
// d = mean absolute luma difference vs the previous frame, in 8-bit code units.
// The mask drops samples with x >= maskX*width AND y >= maskY*height (OBS webcam overlay).
import AVFoundation
import CoreVideo
import QuartzCore

let a = CommandLine.arguments
guard a.count >= 5, let start = Double(a[2]), let secs = Double(a[3]) else {
    FileHandle.standardError.write("usage: luma_mad <video> <start s> <seconds> <out.csv> [maskX] [maskY] [outW outH]\n".data(using: .utf8)!)
    exit(2)
}
let maskX = a.count > 5 ? Double(a[5])! : 0.80
let maskY = a.count > 6 ? Double(a[6])! : 0.74
let rowStep = 32, pxStep = 4

let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let tracks = try await asset.loadTracks(withMediaType: .video)
guard let track = tracks.first else { print("no video track"); exit(1) }
let reader = try AVAssetReader(asset: asset)
reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                               duration: CMTime(seconds: secs, preferredTimescale: 60000))
var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
if a.count > 8, let ow = Int(a[7]), let oh = Int(a[8]) {
    settings[kCVPixelBufferWidthKey as String] = ow
    settings[kCVPixelBufferHeightKey as String] = oh
}
let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
out.alwaysCopiesSampleData = false
reader.add(out)
guard reader.startReading() else { print("startReading failed: \(String(describing: reader.error))"); exit(1) }

var sig: UnsafeMutablePointer<UInt8>? = nil   // previous frame's samples, allocated once
var sigCount = 0
var csv = "frame,pts_s,diff,diff_full,cost_us\n"
var costs: [Double] = []
var idx = 0
var nMasked = 0, nFull = 0

while let sb = out.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    let t0 = CACurrentMediaTime()
    guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess,
          let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { print("lock failed at \(idx)"); exit(1) }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let cols = w / pxStep, rows = h / rowStep
    if sig == nil {
        sigCount = cols * rows
        sig = UnsafeMutablePointer<UInt8>.allocate(capacity: sigCount)
        sig!.initialize(repeating: 0, count: sigCount)
    }
    let mx = Int(Double(cols) * maskX), my = Int(Double(rows) * maskY)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var s = sig!
    var sumKeep = 0, sumMask = 0
    for r in 0..<rows {
        var q = p + (r * rowStep + rowStep / 2) * stride + pxStep / 2
        let rowMasked = r >= my
        var rowKeep = 0, rowMask = 0
        for c in 0..<cols {
            let v = q.pointee
            let d = abs(Int(v) - Int(s.pointee))
            if rowMasked && c >= mx { rowMask += d } else { rowKeep += d }
            s.pointee = v
            s += 1; q += pxStep
        }
        sumKeep += rowKeep; sumMask += rowMask
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    let cost = (CACurrentMediaTime() - t0) * 1e6
    nMasked = (cols - mx) * (rows - my); nFull = cols * rows
    if idx > 0 {
        costs.append(cost)
        let dM = Double(sumKeep) / Double(nFull - nMasked), dF = Double(sumKeep + sumMask) / Double(nFull)
        csv += "\(idx),\(String(format: "%.6f", pts)),\(String(format: "%.5f", dM)),\(String(format: "%.5f", dF)),\(String(format: "%.1f", cost))\n"
    }
    idx += 1
}
if reader.status == .failed { print("reader failed: \(String(describing: reader.error))"); exit(1) }
try csv.write(toFile: a[4], atomically: true, encoding: .utf8)
costs.sort()
guard !costs.isEmpty else { print("no frames"); exit(1) }
func q(_ x: Double) -> Double { costs[min(costs.count - 1, Int(x * Double(costs.count)))] }
print("frames \(idx)  samples/frame \(nFull) (masked out \(nMasked))  grid: 1 row in \(rowStep), 1 pixel in \(pxStep)")
print(String(format: "diff cost us: p50 %.1f  p99 %.1f  max %.1f  (includes lock/unlock)", q(0.5), q(0.99), costs.last!))
print("wrote \(a[4])")
