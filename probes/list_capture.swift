// list_capture: list AVCapture devices and formats, or open one video device and measure what it delivers.
// build: swiftc -O list_capture.swift -o list_capture
// usage: ./list_capture
//            list every video + audio AVCaptureDevice with all formats, plus the CoreMediaIO view of each device
//            (running anywhere? hog pid? device-control pid?). Opens nothing: no permission prompt.
//        ./list_capture --open <uniqueID> <seconds> [--passive] [--format <index>]
//            default:   lock the device, set 1920x1080 420v at ~60 fps, keep the lock while running.
//                       --format <index> picks a format by its number in the list instead (the card can list
//                       two formats that look the same: one uncompressed on the wire, one MJPEG).
//                       This changes the device's format, which is SHARED with any other app using the card.
//            --passive: no lock, no format change of our own; report whatever arrives (the safe first step next to OBS).
//                       AVCaptureSession may still apply its own preset if no other app holds the device lock.
//        --open raises the camera permission prompt for the terminal app the first time.
import AVFoundation
import CoreMediaIO

func fcc(_ v: UInt32) -> String {
  let b = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
  return b.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: b, encoding: .ascii)! : String(format: "0x%08x", v)
}
func describe(_ f: AVCaptureDevice.Format) -> String {
  let fd = f.formatDescription
  if CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Audio {
    guard let a = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return "audio ?" }
    return "\(fcc(a.mFormatID)) \(a.mSampleRate) Hz \(a.mChannelsPerFrame) ch \(a.mBitsPerChannel) bit flags=0x\(String(a.mFormatFlags, radix: 16))"
  }
  let d = CMVideoFormatDescriptionGetDimensions(fd)
  let r = f.videoSupportedFrameRateRanges.map {
    String(format: "%.3f-%.3f (minDur %lld/%d)", $0.minFrameRate, $0.maxFrameRate, $0.minFrameDuration.value, $0.minFrameDuration.timescale)
  }.joined(separator: ", ")
  return "\(d.width)x\(d.height) \(fcc(CMFormatDescriptionGetMediaSubType(fd)))  fps \(r)"
}
func devices(_ m: AVMediaType) -> [AVCaptureDevice] {
  let t: [AVCaptureDevice.DeviceType] = m == .video ? [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera] : [.microphone, .external]
  return AVCaptureDevice.DiscoverySession(deviceTypes: t, mediaType: m, position: .unspecified).devices
}
func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] }

// ---------- list mode ----------
func cmioGet<T>(_ id: CMIOObjectID, _ sel: Int, _ value: inout T) -> Bool {
  var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
  var used: UInt32 = 0
  return CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &used, &value) == 0
}
func cmioString(_ id: CMIOObjectID, _ sel: Int) -> String {
  var s: Unmanaged<CFString>? = nil
  return cmioGet(id, sel, &s) ? (s?.takeRetainedValue() as String? ?? "?") : "?"
}
func listAll() {
  print("camera permission: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)  microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)  (0 not asked, 2 denied, 3 allowed)")
  for m in [AVMediaType.video, .audio] {
    for d in devices(m) {
      print("\n[\(m == .video ? "video" : "audio")] \"\(d.localizedName)\"")
      print("  uniqueID=\(d.uniqueID)  modelID=\(d.modelID)  manufacturer=\(d.manufacturer)  transportType='\(fcc(UInt32(bitPattern: d.transportType)))'  deviceType=\(d.deviceType.rawValue)")
      print("  isInUseByAnotherApplication=\(d.isInUseByAnotherApplication)  isSuspended=\(d.isSuspended)  isConnected=\(d.isConnected)")
      print("  activeFormat: \(describe(d.activeFormat))")
      if m == .video {
        print(String(format: "  active frame duration: min %lld/%d max %lld/%d", d.activeVideoMinFrameDuration.value, d.activeVideoMinFrameDuration.timescale,
                     d.activeVideoMaxFrameDuration.value, d.activeVideoMaxFrameDuration.timescale))
      }
      print("  formats (\(d.formats.count)):")
      for (i, f) in d.formats.enumerated() { print("    [\(i)] \(describe(f))") }
    }
  }
  // CoreMediaIO view: who is running the device, and does any process own it exclusively.
  var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
  var size: UInt32 = 0, used: UInt32 = 0
  CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, &size)
  var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
  CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, size, &used, &ids)
  print("\nCoreMediaIO devices (hog/control pid -1 = nobody; 'n/a' = property not present):")
  for id in ids {
    var running: UInt32 = 0, hog: pid_t = 0, control: pid_t = 0
    let r = cmioGet(id, kCMIODevicePropertyDeviceIsRunningSomewhere, &running) ? "\(running)" : "n/a"
    let h = cmioGet(id, kCMIODevicePropertyHogMode, &hog) ? "\(hog)" : "n/a"
    let c = cmioGet(id, kCMIODevicePropertyDeviceControl, &control) ? "\(control)" : "n/a"
    print("  \"\(cmioString(id, kCMIOObjectPropertyName))\" uid=\(cmioString(id, kCMIODevicePropertyDeviceUID))  runningSomewhere=\(r)  hogPid=\(h)  controlPid=\(c)")
  }
}

// ---------- open mode ----------
final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var pts = [Double](), arrival = [Double](), delay = [Double](), change = [Double]()
  var dropped = 0, dropReasons = [String: Int](), delivered = [String: Int]()
  var prev = [UInt8]()
  var clock = CMClockGetHostTimeClock()
  func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
    let p = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    pts.append(p); arrival.append(CMClockGetTime(CMClockGetHostTimeClock()).seconds); delay.append(CMClockGetTime(clock).seconds - p)
    guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
    let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
    delivered["\(w)x\(h) \(fcc(CVPixelBufferGetPixelFormatType(px)))", default: 0] += 1
    // Repeat detector: every 16th pixel of every 16th row of plane 0, compared with the previous frame.
    CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
    let planar = CVPixelBufferIsPlanar(px)
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(px, 0) : CVPixelBufferGetBaseAddress(px) else { return }
    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(px, 0) : CVPixelBufferGetBytesPerRow(px)
    let b = base.assumingMemoryBound(to: UInt8.self)
    var cur = [UInt8](); cur.reserveCapacity((w / 16 + 1) * (h / 16 + 1))
    for y in Swift.stride(from: 0, to: h, by: 16) { for x in Swift.stride(from: 0, to: w, by: 16) { cur.append(b[y * stride + x]) } }
    if prev.count == cur.count {
      var sum = 0; for i in 0..<cur.count { sum += abs(Int(cur[i]) - Int(prev[i])) }
      change.append(Double(sum) / Double(cur.count))
    }
    prev = cur
  }
  func captureOutput(_ o: AVCaptureOutput, didDrop sb: CMSampleBuffer, from c: AVCaptureConnection) {
    dropped += 1
    let why = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String ?? "unknown"
    dropReasons[why, default: 0] += 1
  }
}

func openDevice(_ uid: String, _ seconds: Double, passive: Bool, formatIndex: Int?) -> Never {
  guard let dev = AVCaptureDevice(uniqueID: uid) else { print("no device with uniqueID \(uid)"); exit(2) }
  // Permission first, so a denial is not mistaken for a busy device.
  switch AVCaptureDevice.authorizationStatus(for: .video) {
  case .authorized: break
  case .notDetermined:
    let sem = DispatchSemaphore(value: 0); var ok = false
    AVCaptureDevice.requestAccess(for: .video) { ok = $0; sem.signal() }
    sem.wait()
    if !ok { print("RESULT permission denied (camera access refused at the prompt)"); exit(5) }
  default: print("RESULT permission denied (System Settings > Privacy & Security > Camera)"); exit(5)
  }
  // "passive" = no explicit lock and no format request. It is NOT guaranteed passive: macOS has no input-priority
  // preset, so the session may still reconfigure the device. The before/after activeFormat lines below show whether it did.
  print("device \"\(dev.localizedName)\"  mode=\(passive ? "passive (no lock, no format request; session may still reconfigure)" : "active (lock + set 1920x1080 420v ~60)")")
  let formatBefore = describe(dev.activeFormat)
  print("before: inUseByAnotherApplication=\(dev.isInUseByAnotherApplication)  activeFormat=\(describe(dev.activeFormat))")
  let session = AVCaptureSession(), out = AVCaptureVideoDataOutput(), sink = Sink(), q = DispatchQueue(label: "frames")
  for n in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification, AVCaptureSession.didStopRunningNotification] {
    NotificationCenter.default.addObserver(forName: n, object: session, queue: nil) { print("EVENT \($0.name.rawValue) \($0.userInfo ?? [:])") }
  }
  session.beginConfiguration()
  let input: AVCaptureDeviceInput
  do { input = try AVCaptureDeviceInput(device: dev) } catch {
    let code = (error as NSError).code
    let why = code == -11815 ? "device in use by another application (-11815)" : code == -11817 ? "device locked for configuration by another process (-11817)"
      : code == -11852 ? "permission denied (-11852)" : "other"
    print("RESULT cannot open device: \(why): \(error)"); exit(3)
  }
  guard session.canAddInput(input) else { print("RESULT session.canAddInput == false (device cannot join a session now)"); exit(3) }
  session.addInput(input)
  // passive: take the device's native format untouched; active: ask for 420v.
  out.videoSettings = passive ? [:] : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
  out.alwaysDiscardsLateVideoFrames = true
  out.setSampleBufferDelegate(sink, queue: q)
  guard session.canAddOutput(out) else { print("RESULT session.canAddOutput == false"); exit(3) }
  session.addOutput(out)
  var locked = false
  if !passive {
    if let i = formatIndex, !dev.formats.indices.contains(i) { print("no format with index \(i)"); exit(64) }
    let want = formatIndex.map { dev.formats[$0] } ?? dev.formats.first {
      let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
      return d.width == 1920 && d.height == 1080 && CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59.9 }
    }
    let byRate: (AVFrameRateRange, AVFrameRateRange) -> Bool = { $0.maxFrameRate < $1.maxFrameRate }
    if let f = want, let r = f.videoSupportedFrameRateRanges.filter({ $0.maxFrameRate >= 59.9 }).min(by: byRate) ?? f.videoSupportedFrameRateRanges.max(by: byRate) {
      do {
        try dev.lockForConfiguration(); locked = true   // stays locked while running so the session cannot reset the format
        dev.activeFormat = f; dev.activeVideoMinFrameDuration = r.minFrameDuration; dev.activeVideoMaxFrameDuration = r.minFrameDuration
        print("lock: ok, asked for \(describe(f))")
      } catch { print("RESULT lockForConfiguration failed: \(error)  (-11817 = locked by another process); continuing without a format change") }
    } else { print("RESULT no 1920x1080 420v format with >= 59.9 fps on this device; continuing without a format change") }
  }
  session.commitConfiguration()
  session.startRunning()
  if let c = session.synchronizationClock { sink.clock = c }
  print("started: isRunning=\(session.isRunning)  activeFormat=\(describe(dev.activeFormat))")
  if describe(dev.activeFormat) != formatBefore { print("RESULT activeFormat changed when this session started (was \(formatBefore)): the session renegotiated the device") }
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("end: activeFormat=\(describe(dev.activeFormat))  isRunning=\(session.isRunning)")
    session.stopRunning(); if locked { dev.unlockForConfiguration() }
    q.sync {}
    let n = sink.pts.count
    guard n > 2 else { print("RESULT frames=\(n) dropped=\(sink.dropped) \(sink.dropReasons): no usable video delivered"); exit(4) }
    func gaps(_ v: [Double]) -> [Double] { zip(v.dropFirst(), v).map { ($0 - $1) * 1000 } }
    let dp = gaps(sink.pts), da = gaps(sink.arrival), med = pct(dp, 0.5)
    print(String(format: "RESULT frames=%d  fps=%.3f  dropped(callback)=%d %@  missing(interval > 1.5x median)=%d", n, Double(n - 1) / (sink.pts[n - 1] - sink.pts[0]),
                 sink.dropped, "\(sink.dropReasons)", dp.filter { $0 > 1.5 * med }.count))
    print("delivered buffers: \(sink.delivered)")
    print(String(format: "timestamp interval ms: p50 %.3f  p99 %.3f  max %.3f", med, pct(dp, 0.99), dp.max()!))
    print(String(format: "arrival interval ms:   p50 %.3f  p99 %.3f  max %.3f", pct(da, 0.5), pct(da, 0.99), da.max()!))
    print(String(format: "arrival minus timestamp ms: p50 %.3f  p99 %.3f  (delay inside the Mac after the driver stamped the frame; not glass-to-glass)",
                 pct(sink.delay, 0.5) * 1000, pct(sink.delay, 0.99) * 1000))
    let c = sink.change
    print(String(format: "frame-to-frame change (mean abs luma diff on a 16x16 grid): identical %d of %d, below 0.5 %d, p50 %.3f  (30 fps game in 60 Hz should show about half identical)",
                 c.filter { $0 == 0 }.count, c.count, c.filter { $0 < 0.5 }.count, pct(c, 0.5)))
    exit(0)
  }
  dispatchMain()
}

let args = CommandLine.arguments
if args.count >= 4, args[1] == "--open", let s = Double(args[3]) {
  let fi = args.firstIndex(of: "--format").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
  openDevice(args[2], s, passive: args.contains("--passive"), formatIndex: fi)
}
else if args.count == 1 { listAll() }
else { print("usage: list_capture | list_capture --open <uniqueID> <seconds> [--passive] [--format <index>]"); exit(64) }
