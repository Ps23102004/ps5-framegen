Implemented `--mode vsync`, `--colorspace`, the report changes and the usage comment. Only `~/Developer/ps5-framegen/probes/present_probe.swift` was edited, and `probes/present_probe` was rebuilt. All runs were small window, `--display-mode keep`, 120 Hz, AC power, Low Power Mode off. At the start `uptime` showed load 2.65 and `pgrep -x ffmpeg | wc -l` showed 10; cliprift was untouched. Headline: in the small window, vsync + `nextDrawable()` + plain present reached the glass about 25 ms after pick time, against 41.5 ms for `--mode link` on the same display.

## (a) Unified diff (`diff -u probes/present_probe.swift.before-vsync probes/present_probe.swift`)
```diff
--- probes/present_probe.swift.before-vsync	2026-11-19 16:27:55
+++ probes/present_probe.swift	2026-11-19 16:29:57
@@ -1,20 +1,34 @@
 // Present-path probe: 420v CVPixelBuffer -> CVMetalTextureCache -> BT.709 shader -> MetalFX spatial 1920x1080 -> 3456x1944
-// -> CAMetalLayer drawable via CAMetalDisplayLink, with HUD. Prints pacing statistics from MTLDrawable.presentedTime.
+// -> CAMetalLayer drawable via CAMetalDisplayLink (--mode link) or via CADisplayLink + layer.nextDrawable() (--mode vsync), with HUD.
+// Prints pacing statistics from MTLDrawable.presentedTime.
 // Build: xcrun swiftc -O -swift-version 5 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 probes/present_probe.swift -o probes/present_probe
 // Run:   probes/present_probe --seconds 10 [--link-hz 60] [--present-every 1] [--latency 2] [--drawables 2] [--hud 1] [--auto-parity 1] [--scaler 1] [--drawable WxH] [--warmup 2] [--expect-ms N]
-//          [--runloop thread|main] [--window small|full] [--video <file> --start <s>] [--mode link|next] [--min-duration s] [--at-time 0]
+//          [--runloop thread|main] [--window small|full] [--video <file> --start <s>] [--mode link|next|vsync] [--min-duration s] [--at-time 0]
 //          [--source index|counter] [--display-mode keep|native120|native5994] [--slots-csv <path>]
+//          [--present plain|at-slot] [--render-delay-ms D] [--colorspace srgb|p3|none]
 //   --source index    (default) content frame = floor((target - t0) * 60): the old 60.000 Hz index. Uses --present-every and the parity lock.
 //   --source counter  gate G1 (PLAN.md 4, 5.2): positions i = 0,1,2.. at c_i = t0 + i*1001/60000 s (t0 = targetPresentationTimestamp of the first callback),
 //                     each reserved a slot by the PLAN.md 5.2 rule (base 0, N 0, eps 1.5 ms, step = round(H/S): 2 at 120 Hz, 1 at 59.94 Hz) on the measured
 //                     slot grid; a callback draws the position reserved for its slot (picture = frame id % frameCount, bar at x = id % 240 steps), else
-//                     presents nothing ("held"). Ignores --present-every and the parity lock. Needs --mode link. Prints the G1 report and ends with a "G1 RESULT:" line.
+//                     presents nothing ("held"). Ignores --present-every and the parity lock. Needs --mode link or vsync. Prints the G1 report and ends with a "G1 RESULT:" line.
+//                     Latency lines exclude the first --warmup (2.0) s after the first present, like the content intervals.
+//   --mode vsync      (needs --source counter) no CAMetalDisplayLink. A CADisplayLink from the chosen NSScreen (displayLink(target:selector:)), range = --link-hz, is added
+//                     to the run loop chosen by --runloop thread|main in .common mode. One tick = one slot; slot time = the link's targetTimestamp (next vsync); the slot index
+//                     advances by max(1, round(gap / S)) per tick and S / the grid are fitted as in link mode (median of the last 120 target differences); the same Pacer reserves.
+//                     Per tick: (a) wait until tick entry + --render-delay-ms (mach_wait_until); (b) record the pick time and take the reserved position, none = "held" and return;
+//                     (c) layer.nextDrawable() (allowsNextDrawableTimeout = true, nil = "skipped"), its blocking time is recorded; (d) encode the link-mode pipeline;
+//                     (e) --present plain = commandBuffer.present(drawable), at-slot = commandBuffer.present(drawable, atTime: slot time); (f) commit.
+//                     In this mode the CSV column callback_time (and "callback" in the latency lines) is the PICK time, after the delay. target_time = the slot time (targetTimestamp).
+//                     present(_:atTime:) is allowed only here: it raises CAMetalDrawableInvalidOperation with a CAMetalDisplayLink drawable (--mode link).
+//   --present         plain (default) | at-slot; only --mode vsync. G1 RESULT prints present=n/a in other modes.
+//   --render-delay-ms D  (default 0) only --mode vsync, see (a).
+//   --colorspace      srgb (default) | p3 (Display P3) | none (layer.colorspace = nil). Every mode; printed in the config: line.
 //   --display-mode    keep (default) leaves the display alone. native120 / native5994 switch the built-in display to its 3456x2234 mode at 120 / 59.94 Hz
 //                     for this process only (CGCompleteDisplayConfiguration .forAppOnly) and print the mode read back; on failure "DISPLAY MODE NOT APPLIED: <reason>".
 //                     (list = print the built-in display's 3456x2234 modes and exit; changes nothing.)
 //   --slots-csv path  (needs --source counter) one row per display-link callback: slot,target_time,callback_time,outcome,content_id,gpu_start,gpu_end,presented_time
 //                     outcome = shown | held | skipped (the position's draw failed). Buffered, written at exit.
-//   --mode next       no display link; prints "DIAGNOSTIC ONLY: no slot grid"; latency timer starts before nextDrawable() is called. Cannot be combined with --source counter.
+//   --mode next       no display link, free-running nextDrawable() loop; prints "DIAGNOSTIC ONLY: no slot grid"; latency timer starts before nextDrawable() is called. Cannot be combined with --source counter.
 //   --pacer-selftest  (hidden) runs the slot rule on synthetic grids for 10 simulated minutes and prints results to compare with `python3 probes/pacer_sim.py`.
 // Keys (window=full only): h = HUD on/off, q or esc = quit. No capture device is opened.
 import AppKit
@@ -43,7 +57,13 @@
 let fullWindow = arg("window", "small") == "full"
 let videoPath = arg("video", "")
 let useScaler = arg("scaler", "1") == "1"            // 0 = skip MetalFX, blit the 1080p texture (cost comparison only)
-let nextMode = arg("mode", "link") == "next"         // next = no display link: a thread loops on layer.nextDrawable()
+let modeArg = arg("mode", "link")
+let nextMode = modeArg == "next"                     // next = no display link: a thread loops on layer.nextDrawable()
+let vsyncMode = modeArg == "vsync"                   // vsync = CADisplayLink clock + nextDrawable() per tick (no CAMetalDisplayLink)
+let presentArg = arg("present", "plain")
+let atSlot = vsyncMode && presentArg == "at-slot"
+let renderDelayMs = Double(arg("render-delay-ms", "0")) ?? -1
+let colorspaceArg = arg("colorspace", "srgb")
 let minDuration = Double(arg("min-duration", "0"))!   // present(afterMinimumDuration:) in seconds, 0 = plain present
 let autoParity = arg("auto-parity", "1") == "1"
 let drawableArg = arg("drawable", "")                 // WxH in pixels; default = screen backing size
@@ -53,6 +73,8 @@
 let slotsCSV = arg("slots-csv", "")
 let counterMode = sourceArg == "counter"
 let contentH = 1001.0 / 60000.0                       // s between content positions (59.94 Hz)
+var tbInfo = mach_timebase_info_data_t(); let _ = mach_timebase_info(&tbInfo)
+let renderDelayTicks = UInt64(renderDelayMs / 1000 * 1e9 * Double(tbInfo.denom) / Double(tbInfo.numer))   // mach_wait_until units
 
 // ---------- slot reservation (PLAN.md 5.2): port of run() in probes/pacer_sim.py. Pure logic, units are the caller's (ms in the self-test, s live) ----------
 struct SlotGrid {
@@ -113,7 +135,13 @@
 if CommandLine.arguments.contains("--pacer-selftest") { pacerSelftest() }
 if sourceArg != "index" && sourceArg != "counter" { die("--source must be index or counter (got \(sourceArg))") }
 if !["keep", "native120", "native5994", "list"].contains(displayModeArg) { die("--display-mode must be keep, native120 or native5994 (got \(displayModeArg))") }
-if counterMode && nextMode { die("--source counter needs the display link's slot grid; it cannot be combined with --mode next. Use --mode link, or --source index for the nextDrawable diagnostic.") }
+if !["link", "next", "vsync"].contains(modeArg) { die("--mode must be link, next or vsync (got \(modeArg))") }
+if !["plain", "at-slot"].contains(presentArg) { die("--present must be plain or at-slot (got \(presentArg))") }
+if !["srgb", "p3", "none"].contains(colorspaceArg) { die("--colorspace must be srgb, p3 or none (got \(colorspaceArg))") }
+if renderDelayMs < 0 { die("--render-delay-ms must be a number >= 0") }
+if counterMode && nextMode { die("--source counter needs a slot grid; it cannot be combined with --mode next. Use --mode link or vsync, or --source index for the nextDrawable diagnostic.") }
+if vsyncMode && !counterMode { die("--mode vsync needs --source counter") }
+if (presentArg != "plain" || renderDelayMs > 0) && !vsyncMode { die("--present at-slot and --render-delay-ms need --mode vsync") }
 if !slotsCSV.isEmpty && !counterMode { die("--slots-csv needs --source counter") }
 
 let shaderSource = """
@@ -344,6 +372,7 @@
     var slot: Int32 = 0, contentId: Int32 = -1
     var outcome: UInt8 = 1, handlerRan: UInt8 = 0      // outcome: 0 shown, 1 held, 2 skipped
     var target = 0.0, cb = 0.0, gpuStart = 0.0, gpuEnd = 0.0, presented = 0.0
+    var ndWait = 0.0, ndTried: UInt8 = 0, ndNil: UInt8 = 0   // --mode vsync: nextDrawable() blocking time, tried, returned nil
 }
 func allocate<T>(_ n: Int, _ v: T) -> UnsafeMutablePointer<T> {
     let p = UnsafeMutablePointer<T>.allocate(capacity: n); p.initialize(repeating: v, count: n); return p
@@ -364,7 +393,7 @@
     var slotIdx = 0
     var grid = SlotGrid(), pacer = Pacer(), nextPos = 0, t0c = 0.0, lastTarget = 0.0, diffN = 0
     var resHead = 0, resTail = 0, lastShownId = -1, stepUsed = 0, sMedian = 0.0
-    var missedSlot = 0, nominalS = 0, gapCallbacks = 0, queueFull = 0, posOverflow = 0, rowOverflow = 0, shownDraws = 0
+    var missedSlot = 0, nominalS = 0, gapCallbacks = 0, queueFull = 0, posOverflow = 0, rowOverflow = 0, shownDraws = 0, nilDrawables = 0
     var barColor = SIMD4<Float>(1, 0, 1, 1)
     let parity = Atomic<Int>(Int(arg("parity", "0"))!)   // which callbacks present when present-every > 1; flipped when presents land one refresh late
     var linkThread: Thread?
@@ -389,16 +418,31 @@
         cbTime.append(now)
         lead.append(update.targetPresentationTimestamp - now)
         tgtGap.append(update.targetPresentationTimestamp - update.targetTimestamp)
-        if counterMode { counterCallback(update, now: now); return }
+        if counterMode { counterCallback(target: update.targetPresentationTimestamp, now: now, drawable: update.drawable); return }
         if (callbacks + parity.load(ordering: .relaxed)) % presentEvery != 0 { return }
         render(update.drawable, target: update.targetPresentationTimestamp, now: now)
     }
 
-    /// --source counter. Slot index advances by round(target difference / S) per callback, so a skipped callback does not shift the grid; slot time = targetPresentationTimestamp; S = median of the last 120 target differences.
+    /// --mode vsync: one CADisplayLink tick = one slot (slot time = targetTimestamp). No print, no file I/O here.
+    @objc func vsyncTick(_ dl: CADisplayLink) {
+        let entry = CACurrentMediaTime(), entryTicks = mach_absolute_time()
+        if renderDelayTicks > 0 { mach_wait_until(entryTicks + renderDelayTicks) }   // (a)
+        let now = CACurrentMediaTime()                 // pick time
+        if linkThread != nil && Thread.current != linkThread { wrongThread += 1 }
+        let target = dl.targetTimestamp
+        if t0 == 0 { t0 = target }
+        callbacks += 1
+        cbTime.append(now)
+        lead.append(target - entry)
+        counterCallback(target: target, now: now, drawable: nil)
+    }
+
+    /// --source counter. Slot index advances by round(target difference / S) per callback, so a skipped callback does not shift the grid; slot time = `target`
+    /// (link mode: targetPresentationTimestamp, vsync mode: targetTimestamp); S = median of the last 120 target differences.
+    /// `drawable` is nil in vsync mode: the drawable is taken with layer.nextDrawable() only after a position was reserved for this slot.
     /// No print, no file I/O, no allocation here beyond what render() already does.
-    func counterCallback(_ update: CAMetalDisplayLink.Update, now: Double) {
+    func counterCallback(target: Double, now: Double, drawable: CAMetalDrawable?) {
         let cbN = callbacks - 1                        // row in the log: one per callback
-        let target = update.targetPresentationTimestamp
         var S = 1.0 / Double(linkHz)
         if cbN > 0 {
             diffRing[diffN % 120] = target - lastTarget; diffN += 1
@@ -434,7 +478,15 @@
         if row >= 0 { rows[row].slot = Int32(idx); rows[row].target = target; rows[row].cb = now } else { rowOverflow += 1 }
         if resHead < resTail && resSlot[resHead % resCap] == idx {
             let id = resId[resHead % resCap]; resHead += 1
-            let ok = render(update.drawable, target: target, now: now, content: id, row: row)
+            var d = drawable
+            if vsyncMode {                             // (c) blocking time of nextDrawable() is logged; nil = skipped
+                let t1 = CACurrentMediaTime()
+                d = layer.nextDrawable()
+                if row >= 0 { rows[row].ndWait = CACurrentMediaTime() - t1; rows[row].ndTried = 1; rows[row].ndNil = d == nil ? 1 : 0 }
+                if d == nil { nilDrawables += 1 }
+            }
+            var ok = false
+            if let d { ok = render(d, target: target, now: now, content: id, row: row) }
             if ok { lastShownId = id; shownDraws += 1 }
             if row >= 0 { rows[row].outcome = ok ? 0 : 2; rows[row].contentId = Int32(id) }
         } else if row >= 0 {                           // nothing reserved for this slot: no present, the previous image stays on glass
@@ -530,7 +582,9 @@
         }
         // Measured 2026-11-19: with a CAMetalDisplayLink drawable, present(atTime:) and present(afterMinimumDuration:) both raise
         // CAMetalDrawableInvalidOperation. --at-time 1 and --min-duration in link mode exist only to reproduce that.
-        if minDuration > 0 { cb.present(drawable, afterMinimumDuration: minDuration) }
+        // --mode vsync has no CAMetalDisplayLink on the layer, so present(_:atTime:) is allowed there: slot time = the link's targetTimestamp.
+        if vsyncMode { if atSlot { cb.present(drawable, atTime: target) } else { cb.present(drawable) } }
+        else if minDuration > 0 { cb.present(drawable, afterMinimumDuration: minDuration) }
         else if atTime { cb.present(drawable, atTime: target) } else { cb.present(drawable) }
         cb.commit()
         cpu.append(CACurrentMediaTime() - (cpuStart ?? now))
@@ -618,7 +672,8 @@
 layer.presentsWithTransaction = false
 layer.maximumDrawableCount = drawablesArg
 layer.isOpaque = true
-layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
+layer.colorspace = colorspaceArg == "none" ? nil : CGColorSpace(name: colorspaceArg == "p3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
+layer.allowsNextDrawableTimeout = true
 layer.contentsScale = screen.backingScaleFactor
 // Drawable is always full-screen pixel size so GPU cost matches the real app even in the small window.
 layer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
@@ -642,23 +697,43 @@
 if fullWindow { window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); app.activate(ignoringOtherApps: true) } else { window.orderFrontRegardless() }
 
 let renderer = Renderer()
-let link = CAMetalDisplayLink(metalLayer: layer)
-print("link defaults: preferredFrameLatency=\(link.preferredFrameLatency) range=\(link.preferredFrameRateRange) drawableCount=\(layer.maximumDrawableCount)")
-link.delegate = renderer
-link.preferredFrameRateRange = CAFrameRateRange(minimum: linkHz, maximum: linkHz, preferred: linkHz)
-if latencyArg >= 0 { link.preferredFrameLatency = latencyArg }
-if nextMode {
-    link.invalidate()   // exactly once: a second invalidate() crashed (SIGSEGV in CAMetalLayerSetMetalLinkToken, measured 2026-11-19)
+let link: CAMetalDisplayLink? = vsyncMode ? nil : CAMetalDisplayLink(metalLayer: layer)   // --mode vsync: no CAMetalDisplayLink on this layer
+var vsyncLink: CADisplayLink?
+if let link {
+    print("link defaults: preferredFrameLatency=\(link.preferredFrameLatency) range=\(link.preferredFrameRateRange) drawableCount=\(layer.maximumDrawableCount)")
+    link.delegate = renderer
+    link.preferredFrameRateRange = CAFrameRateRange(minimum: linkHz, maximum: linkHz, preferred: linkHz)
+    if latencyArg >= 0 { link.preferredFrameLatency = latencyArg }
+}
+if vsyncMode {
+    let dl = screen.displayLink(target: renderer, selector: #selector(Renderer.vsyncTick(_:)))
+    dl.preferredFrameRateRange = CAFrameRateRange(minimum: linkHz, maximum: linkHz, preferred: linkHz)
+    vsyncLink = dl
+    print("vsync link: CADisplayLink from NSScreen, range=\(dl.preferredFrameRateRange) drawableCount=\(layer.maximumDrawableCount)")
+    if arg("runloop", "thread") == "main" {
+        renderer.linkThread = Thread.main
+        dl.add(to: .main, forMode: .common)
+    } else {
+        let thread = Thread {
+            renderer.linkThread = Thread.current
+            dl.add(to: .current, forMode: .common)
+            RunLoop.current.run()
+        }
+        thread.name = "present"; thread.qualityOfService = .userInteractive
+        thread.start()
+    }
+} else if nextMode {
+    link!.invalidate()   // exactly once: a second invalidate() crashed (SIGSEGV in CAMetalLayerSetMetalLinkToken, measured 2026-11-19)
     let thread = Thread { renderer.loopNextDrawable(layer) }
     thread.name = "present"; thread.qualityOfService = .userInteractive
     thread.start()
 } else if arg("runloop", "thread") == "main" {
     renderer.linkThread = Thread.main
-    link.add(to: .main, forMode: .common)
+    link!.add(to: .main, forMode: .common)
 } else {
     let thread = Thread {
         renderer.linkThread = Thread.current
-        link.add(to: .current, forMode: .default)
+        link!.add(to: .current, forMode: .default)
         RunLoop.current.run()
     }
     thread.name = "present"; thread.qualityOfService = .userInteractive
@@ -685,16 +760,18 @@
 func counterReport(_ r: Renderer) {
     let n = min(r.callbacks, rowCap)
     var shown = 0, held = 0, skipped = 0, zeroPresented = 0, handlerNotRun = 0
-    var lat: [Double] = [], pres: [(t: Double, id: Int)] = []
+    var lat: [(t: Double, lat: Double, late: Double)] = [], pres: [(t: Double, id: Int)] = []   // t = presented_time; late = presented - slot time
+    var ndw: [(cb: Double, w: Double)] = [], ndNils = 0
     var shownId = [Bool](repeating: false, count: posCap)
     for i in 0..<n {
         let w = rows[i]
+        if w.ndTried != 0 { ndw.append((w.cb, w.ndWait)); ndNils += Int(w.ndNil) }
         switch w.outcome {
         case 0:
             shown += 1
             if w.contentId >= 0 && Int(w.contentId) < posCap { shownId[Int(w.contentId)] = true }
             if w.presented == 0 { zeroPresented += 1; if w.handlerRan == 0 { handlerNotRun += 1 } }
-            else { lat.append(w.presented - w.cb); pres.append((w.presented, Int(w.contentId))) }
+            else { lat.append((w.presented, w.presented - w.cb, w.presented - w.target)); pres.append((w.presented, Int(w.contentId))) }
         case 1: held += 1
         default: skipped += 1
         }
@@ -708,17 +785,27 @@
     var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3)
     print(String(format: "load average at exit: %.2f %.2f %.2f", la[0], la[1], la[2]))
     func q(_ s: [Double], _ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
-    let ls = lat.sorted()
+    // Latency lines exclude the first `warm` s after the first non-zero presented time, like the content intervals below.
+    let warm = Double(arg("warmup", "2"))!
+    let first = pres.first?.t ?? 0
+    let steady = lat.filter { $0.t >= first + warm }
+    let ls = steady.map { $0.lat }.sorted(), lt = steady.map { $0.late }.sorted()
     var p99 = Double.nan
-    if ls.isEmpty { print("latency (presented_time - callback_time, shown rows, non-zero presented): no samples") }
+    if ls.isEmpty { print("latency (presented_time - callback_time, shown rows, non-zero presented, first \(warm) s excluded): no samples") }
     else {
         p99 = q(ls, 0.99) * 1000
-        print(String(format: "latency (presented_time - callback_time, shown rows, non-zero presented): n=%d p50=%.3f p99=%.3f max=%.3f ms", ls.count, q(ls, 0.5) * 1000, p99, ls[ls.count - 1] * 1000))
+        print(String(format: "latency (presented_time - callback_time, shown rows, non-zero presented, first %.1f s excluded): n=%d p50=%.3f p99=%.3f max=%.3f ms", warm, ls.count, q(ls, 0.5) * 1000, p99, ls[ls.count - 1] * 1000))
+        let lateN = lt.filter { $0 > S / 2 }.count
+        print(String(format: "presented_time - slot time (target_time of the row, same rows): p50=%.3f p99=%.3f max=%.3f ms; rows more than half a slot (%.3f ms) late: %d of %d", q(lt, 0.5) * 1000, q(lt, 0.99) * 1000, lt[lt.count - 1] * 1000, S * 500, lateN, lt.count))
     }
+    if vsyncMode {
+        let t0r = ndw.first?.cb ?? 0
+        let nw = ndw.filter { $0.cb >= t0r + warm }.map { $0.w }.sorted()
+        if nw.isEmpty { print("nextDrawable() wait: no samples; nil drawables: \(ndNils)") }
+        else { print(String(format: "nextDrawable() wait (first %.1f s excluded): n=%d p50=%.3f p99=%.3f max=%.3f ms; nil drawables (whole run): %d", warm, nw.count, q(nw, 0.5) * 1000, q(nw, 0.99) * 1000, nw[nw.count - 1] * 1000, ndNils)) }
+    }
     // Content intervals: consecutive shown rows with non-zero presented time and different content ids. A shown row with presented_time 0 is left out,
     // so the interval across it is about two positions long and counts as out of band (it is not hidden).
-    let warm = Double(arg("warmup", "2"))!
-    let first = pres.first?.t ?? 0
     var ivs: [(iv: Double, t: Double)] = [], inBand = 0, outT: [Double] = []
     var outList: [String] = []
     for j in 1..<max(1, pres.count) where pres[j].id != pres[j - 1].id && pres[j].t >= first + warm {
@@ -741,9 +828,10 @@
     }
     print("slots: shown=\(shown) held=\(held) skipped=\(skipped) (callbacks=\(r.callbacks), rows=\(n)); shown rows with presented_time == 0: \(zeroPresented) (of which handler had not run at exit: \(handlerNotRun))")
     print("pacer: corrections=\(r.pacer.corrections) collision=\(r.pacer.collision) pushedLate=\(r.pacer.pushedLate) catchUpSkip=\(r.pacer.catchUpSkip); positions reserved=\(reserved) never shown=\(neverShown) (slot already past when due: \(r.missedSlot)) pending at exit=\(pendingAtExit) dropped at reservation=\(r.pacer.collision + r.pacer.catchUpSkip)")
-    print("housekeeping: nominalS=\(r.nominalS) gapCallbacks=\(r.gapCallbacks) reservationQueueFull=\(r.queueFull) positionLogFull=\(r.posOverflow) rowLogFull=\(r.rowOverflow)")
-    print(String(format: "G1 RESULT: latency_p99_ms=%@ in_band_pct=%@ max_glitches_per_15s=%d",
-                 p99.isNaN ? "n/a" : String(format: "%.2f", p99), inPct.isNaN ? "n/a" : String(format: "%.3f", inPct), worst15))
+    print("housekeeping: nominalS=\(r.nominalS) gapCallbacks=\(r.gapCallbacks) reservationQueueFull=\(r.queueFull) positionLogFull=\(r.posOverflow) rowLogFull=\(r.rowOverflow) nilDrawables=\(r.nilDrawables)")
+    print(String(format: "G1 RESULT: latency_p99_ms=%@ in_band_pct=%@ max_glitches_per_15s=%d mode=%@ present=%@ render_delay_ms=%g",
+                 p99.isNaN ? "n/a" : String(format: "%.2f", p99), inPct.isNaN ? "n/a" : String(format: "%.3f", inPct), worst15,
+                 vsyncMode ? "vsync" : "link", vsyncMode ? presentArg : "n/a", renderDelayMs))
     if !slotsCSV.isEmpty {
         var s = "slot,target_time,callback_time,outcome,content_id,gpu_start,gpu_end,presented_time\n"
         s.reserveCapacity(n * 100)
@@ -759,7 +847,7 @@
 }
 
 func finish() -> Never {
-    if !nextMode { link.invalidate() }
+    if vsyncMode { vsyncLink?.invalidate() } else if !nextMode { link?.invalidate() }
     Thread.sleep(forTimeInterval: 0.3)   // let the last presented handlers arrive; probe shutdown only
     let r = renderer
     if nextMode { print("DIAGNOSTIC ONLY: no slot grid") }
@@ -769,18 +857,18 @@
         func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] * scale }
         print(String(format: "%@: n=%d min=%.3f p50=%.3f p99=%.3f max=%.3f mean=%.3f ms", name, s.count, s[0] * scale, q(0.5), q(0.99), s[s.count - 1] * scale, s.reduce(0, +) / Double(s.count) * scale))
     }
-    print("config: mode=\(nextMode ? "next" : "link") min-duration=\(minDuration) link-hz=\(linkHz) present-every=\(presentEvery) latency=\(link.preferredFrameLatency) drawables=\(layer.maximumDrawableCount) at-time=\(atTime) hud=\(hud.visible.load(ordering: .relaxed)) window=\(fullWindow ? "full" : "small") drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height)) scaler=\(useScaler) picture=\(videoPath.isEmpty ? "synthetic" : "video") source=\(sourceArg) display-mode=\(displayModeArg)")
+    print("config: mode=\(modeArg) present=\(vsyncMode ? presentArg : "n/a") render-delay-ms=\(renderDelayMs) colorspace=\(colorspaceArg) min-duration=\(minDuration) link-hz=\(linkHz) present-every=\(presentEvery) latency=\(link.map { "\($0.preferredFrameLatency)" } ?? "n/a") drawables=\(layer.maximumDrawableCount) at-time=\(atTime) hud=\(hud.visible.load(ordering: .relaxed)) window=\(fullWindow ? "full" : "small") drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height)) scaler=\(useScaler) picture=\(videoPath.isEmpty ? "synthetic" : "video") source=\(sourceArg) display-mode=\(displayModeArg)")
     print("callbacks=\(r.callbacks) parityFlips=\(r.parityFlips) wrongThread=\(r.wrongThread) textureFailures=\(r.texFail) presentedHandlers=\(r.presented.count) presentedTime==0: \(r.presented.filter { $0.actual == 0 }.count)")
     stats("callback interval", zip(r.cbTime.dropFirst(), r.cbTime).map { $0 - $1 })
-    stats("lead (targetPresentationTimestamp - callback now)", r.lead)
-    stats("targetPresentationTimestamp - targetTimestamp", r.tgtGap)
+    stats(vsyncMode ? "lead (targetTimestamp - tick entry)" : "lead (targetPresentationTimestamp - callback now)", r.lead)
+    if !vsyncMode { stats("targetPresentationTimestamp - targetTimestamp", r.tgtGap) }
     stats("callback CPU time", r.cpu)
     stats("GPU time (GPUEndTime - GPUStartTime)", r.gpu)
     let all = r.presented.filter { $0.actual > 0 }.sorted { $0.actual < $1.actual }
     let warmup = Double(arg("warmup", "2"))!   // seconds after the first present that are left out of the present statistics
     let ok = all.filter { $0.actual >= (all.first?.actual ?? 0) + warmup }
     print("present statistics exclude the first \(warmup) s (\(all.count - ok.count) frames)")
-    if !nextMode { stats("presentedTime - targetPresentationTimestamp", ok.map { $0.actual - $0.target }) }
+    if !nextMode { stats(vsyncMode ? "presentedTime - slot time (targetTimestamp)" : "presentedTime - targetPresentationTimestamp", ok.map { $0.actual - $0.target }) }
     stats("glass latency (presentedTime - time the frame was picked)", ok.map { $0.actual - $0.picked })
     if counterMode { counterReport(r); r.lock.unlock(); exit(0) }   // the index-source interval / glitch lines below do not apply to the counter source
     let iv = zip(ok.dropFirst(), ok).map { $0.actual - $1.actual }
```
The Pacer, SlotGrid and the 8-column CSV are reused unchanged. Beyond what the brief specified, the diff adds: argument validation (`--mode vsync` needs `--source counter`; `--present at-slot` and `--render-delay-ms` need `--mode vsync`) and `nilDrawables` in the housekeeping line.

## (b) Verification commands with real output

**1. Build**
```
xcrun swiftc -O -swift-version 5 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 probes/present_probe.swift -o probes/present_probe
```
- Exit 0, zero errors.
- The only warnings are the five AVAssetReader deprecations at lines 217, 225, 226, 227 and 228: `tracks(withMediaType:)`, `alwaysCopiesSampleData`, `add`, `startReading`, `copyNextSampleBuffer`. That block is the old lines 189-200, which I did not touch, and the SKILL accepts these in the probe.
- No warning in any line I touched.

**2. `probes/present_probe --pacer-selftest`**

I ran it once before my edit, after my edit, and diffed the two outputs. `diff` printed IDENTICAL. After-change output:
```
swift 120Hz S=1000/120 ms step=2 phase=0.0 jitter=+-1ms: slots=35964 corrections=73 dropped=0 (collision=0 catchUpSkip=0) pushed=0 early=0 shared=0 fnv=10088099095227764020
swift 120Hz S=1000/120 ms step=2 phase=0.3 jitter=+-1ms: slots=35964 corrections=72 dropped=0 (collision=0 catchUpSkip=0) pushed=0 early=0 shared=0 fnv=3559300861962666869
swift 120Hz S=1000/120 ms step=2 phase=0.8 jitter=+-1ms: slots=35964 corrections=72 dropped=0 (collision=0 catchUpSkip=0) pushed=0 early=0 shared=0 fnv=12545786513018818389
swift 59.94Hz S=H*(1+50e-6) step=1 phase=0.0 jitter=+-1ms: slots=35962 corrections=3 dropped=2 (collision=0 catchUpSkip=2) pushed=2 early=0 shared=0 fnv=16239421811236373615
swift 59.94Hz S=H*(1+50e-6) step=1 phase=0.3 jitter=+-1ms: slots=35962 corrections=2 dropped=2 (collision=0 catchUpSkip=2) pushed=2 early=0 shared=0 fnv=5990378160207900034
swift 59.94Hz S=H*(1+50e-6) step=1 phase=0.8 jitter=+-1ms: slots=35963 corrections=1 dropped=1 (collision=0 catchUpSkip=1) pushed=1 early=0 shared=0 fnv=13155799861410150939
```

**3. Four vsync runs.** Common flags: `--seconds 20 --link-hz 120 --source counter --display-mode keep --window small --video "$V" --start 2904 --mode vsync`, plus the extra flags shown in each heading. Common lines in all four runs:
- `display mode applied: keep: current mode 2056x1329 pt, 4112x2658 px, 120.000 Hz`
- `link rate: requested 120.0 Hz, measured 120.000 Hz (1 / S median); step = 2 slot(s) per position; S median = 8.3333 ms (last 120 target differences)`
- `pmset -g batt (first line): Now drawing from 'AC Power'`
- `pmset -g | grep lowpowermode: lowpowermode         0`

A first attempt at these runs passed `--present at-slot` as one quoted word (shell word-splitting slip). The probe ignored it and ran as `present=plain`, which its own `G1 RESULT` line showed. I discarded that attempt and re-ran all four properly. The output below is from the re-run.

```
=== vsync --present plain
load average at exit: 2.59 2.73 3.52
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=1076 p50=24.912 p99=24.950 max=33.231 ms
presented_time - slot time (target_time of the row, same rows): p50=16.650 p99=16.666 max=24.992 ms; rows more than half a slot (4.167 ms) late: 1076 of 1076
nextDrawable() wait (first 2.0 s excluded): n=1079 p50=0.095 p99=0.195 max=1.550 ms; nil drawables (whole run): 0
content intervals (first 2.0 s excluded): count=1076 within 16.683 +- 2 ms: 1072 = 99.628 %, out of band: 4, max out-of-band in any rolling 15 s window: 4
out-of-band intervals (interval@time since first present, first 4 of 4): 25.00ms@8.28s 25.00ms@8.79s 8.33ms@8.80s 25.00ms@16.59s
slots: shown=1199 held=1201 skipped=0 (callbacks=2400, rows=2400); shown rows with presented_time == 0: 2 (of which handler had not run at exit: 0)
pacer: corrections=3 collision=0 pushedLate=0 catchUpSkip=0; positions reserved=1204 never shown=0 (slot already past when due: 0) pending at exit=5 dropped at reservation=0
housekeeping: nominalS=1 gapCallbacks=0 reservationQueueFull=0 positionLogFull=0 rowLogFull=0 nilDrawables=0
G1 RESULT: latency_p99_ms=24.95 in_band_pct=99.628 max_glitches_per_15s=4 mode=vsync present=plain render_delay_ms=0
config: mode=vsync present=plain render-delay-ms=0.0 colorspace=srgb min-duration=0.0 link-hz=120.0 present-every=1 latency=n/a drawables=2 at-time=false hud=true window=small drawable=4112x2658 scaler=true picture=video source=counter display-mode=keep

=== vsync --present at-slot
load average at exit: 3.42 2.92 3.57
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=325 p50=24.927 p99=24.963 max=33.264 ms
presented_time - slot time (target_time of the row, same rows): p50=16.648 p99=16.669 max=25.001 ms; rows more than half a slot (4.167 ms) late: 325 of 325
nextDrawable() wait (first 2.0 s excluded): n=1079 p50=0.087 p99=0.180 max=1.936 ms; nil drawables (whole run): 0
content intervals (first 2.0 s excluded): count=325 within 16.683 +- 2 ms: 320 = 98.462 %, out of band: 5, max out-of-band in any rolling 15 s window: 5
out-of-band intervals (interval@time since first present, first 5 of 5): 25.00ms@6.43s 8.34ms@6.44s 25.00ms@6.93s 8.33ms@6.94s 8.33ms@7.40s
slots: shown=1199 held=1201 skipped=0 (callbacks=2400, rows=2400); shown rows with presented_time == 0: 753 (of which handler had not run at exit: 0)
pacer: corrections=3 collision=0 pushedLate=0 catchUpSkip=0; positions reserved=1204 never shown=0 (slot already past when due: 0) pending at exit=5 dropped at reservation=0
housekeeping: nominalS=1 gapCallbacks=0 reservationQueueFull=0 positionLogFull=0 rowLogFull=0 nilDrawables=0
G1 RESULT: latency_p99_ms=24.96 in_band_pct=98.462 max_glitches_per_15s=5 mode=vsync present=at-slot render_delay_ms=0
config: mode=vsync present=at-slot render-delay-ms=0.0 colorspace=srgb min-duration=0.0 link-hz=120.0 present-every=1 latency=n/a drawables=2 at-time=false hud=true window=small drawable=4112x2658 scaler=true picture=video source=counter display-mode=keep

=== vsync --present plain --render-delay-ms 4
load average at exit: 3.37 2.94 3.56
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=1076 p50=20.776 p99=29.137 max=29.218 ms
presented_time - slot time (target_time of the row, same rows): p50=16.657 p99=24.999 max=25.000 ms; rows more than half a slot (4.167 ms) late: 1076 of 1076
nextDrawable() wait (first 2.0 s excluded): n=1079 p50=0.080 p99=0.160 max=0.190 ms; nil drawables (whole run): 0
content intervals (first 2.0 s excluded): count=1076 within 16.683 +- 2 ms: 511 = 47.491 %, out of band: 565, max out-of-band in any rolling 15 s window: 511
out-of-band intervals (interval@time since first present, first 40 of 565): 25.00ms@2.12s 8.33ms@2.13s 25.00ms@2.52s 8.33ms@2.53s 25.00ms@2.66s 8.33ms@2.67s 25.00ms@2.79s 8.33ms@2.80s 25.00ms@2.92s 8.33ms@2.93s ... (alternating 25.00 / 8.33 ms; the first 10 of the 40 printed)
slots: shown=1198 held=1200 skipped=0 (callbacks=2398, rows=2398); shown rows with presented_time == 0: 2 (of which handler had not run at exit: 0)
pacer: corrections=3 collision=0 pushedLate=0 catchUpSkip=0; positions reserved=1205 never shown=1 (slot already past when due: 1) pending at exit=6 dropped at reservation=0
housekeeping: nominalS=1 gapCallbacks=1 reservationQueueFull=0 positionLogFull=0 rowLogFull=0 nilDrawables=0
G1 RESULT: latency_p99_ms=29.14 in_band_pct=47.491 max_glitches_per_15s=511 mode=vsync present=plain render_delay_ms=4
config: mode=vsync present=plain render-delay-ms=4.0 colorspace=srgb ... (same as above)

=== vsync --present at-slot --render-delay-ms 4
load average at exit: 3.24 2.95 3.54
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=1075 p50=20.448 p99=29.132 max=29.226 ms
presented_time - slot time (target_time of the row, same rows): p50=16.655 p99=24.998 max=25.000 ms; rows more than half a slot (4.167 ms) late: 1075 of 1075
nextDrawable() wait (first 2.0 s excluded): n=1079 p50=0.045 p99=0.138 max=0.270 ms; nil drawables (whole run): 0
content intervals (first 2.0 s excluded): count=1075 within 16.683 +- 2 ms: 605 = 56.279 %, out of band: 470, max out-of-band in any rolling 15 s window: 410
out-of-band intervals (first 40 of 470): 25.00ms@2.07s 8.33ms@2.10s 25.00ms@2.16s 8.33ms@2.17s ... (same 25.00 / 8.33 ms pairs)
slots: shown=1198 held=1200 skipped=0 (callbacks=2398, rows=2398); shown rows with presented_time == 0: 3 (of which handler had not run at exit: 0)
pacer: corrections=3 collision=0 pushedLate=0 catchUpSkip=0; positions reserved=1205 never shown=1 (slot already past when due: 1) pending at exit=6 dropped at reservation=0
housekeeping: nominalS=1 gapCallbacks=1 reservationQueueFull=0 positionLogFull=0 rowLogFull=0 nilDrawables=0
G1 RESULT: latency_p99_ms=29.13 in_band_pct=56.279 max_glitches_per_15s=410 mode=vsync present=at-slot render_delay_ms=4
```
The two `...` abbreviations are where I shortened the pasted text. The complete report text for each run is under `$TMPDIR` as `run_<flags>.txt`. All four runs exited 0 with no `FATAL`.

**4. Unchanged-behaviour run** (`--mode link`, 20 s, no `--present`)
```
display mode applied: keep: current mode 2056x1329 pt, 4112x2658 px, 120.000 Hz
link rate: requested 120.0 Hz, measured 120.000 Hz (1 / S median); step = 2 slot(s) per position; S median = 8.3333 ms (last 120 target differences)
pmset -g batt (first line): Now drawing from 'AC Power'
pmset -g | grep lowpowermode: lowpowermode         0
load average at exit: 2.97 2.90 3.51
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=1073 p50=41.525 p99=41.605 max=41.623 ms
presented_time - slot time (target_time of the row, same rows): p50=-0.018 p99=-0.000 max=0.004 ms; rows more than half a slot (4.167 ms) late: 0 of 1073
content intervals (first 2.0 s excluded): count=1073 within 16.683 +- 2 ms: 1070 = 99.720 %, out of band: 3, max out-of-band in any rolling 15 s window: 2
out-of-band intervals (interval@time since first present, first 3 of 3): 25.00ms@3.27s 25.00ms@11.58s 25.00ms@19.89s
slots: shown=1195 held=1202 skipped=0 (callbacks=2397, rows=2397); shown rows with presented_time == 0: 3 (of which handler had not run at exit: 0)
pacer: corrections=8 collision=1 pushedLate=2 catchUpSkip=2; positions reserved=1200 never shown=1 (slot already past when due: 1) pending at exit=4 dropped at reservation=3
housekeeping: nominalS=1 gapCallbacks=1 reservationQueueFull=0 positionLogFull=0 rowLogFull=0 nilDrawables=0
G1 RESULT: latency_p99_ms=41.60 in_band_pct=99.720 max_glitches_per_15s=2 mode=link present=n/a render_delay_ms=0
config: mode=link present=n/a render-delay-ms=0.0 colorspace=srgb min-duration=0.0 link-hz=120.0 present-every=1 latency=2.0 drawables=2 at-time=false hud=true window=small drawable=4112x2658 scaler=true picture=video source=counter display-mode=keep
```
Latency p50 is 41.5 ms, not near 49.9 ms. The display is at 120 Hz, and 41.6 ms is the brief's own 120 Hz figure; 49.9 ms is its 59.94 Hz figure. So 41.5 ms matches the earlier G1 120 Hz measurement, and the link path is behaving as before.

**5. `--colorspace` runs** (`--mode link`, 8 s)
```
=== none
config: mode=link present=n/a render-delay-ms=0.0 colorspace=none min-duration=0.0 link-hz=120.0 present-every=1 latency=2.0 drawables=2 at-time=false hud=true window=small drawable=4112x2658 scaler=true picture=video source=counter display-mode=keep
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=355 p50=41.517 p99=41.586 max=41.605 ms
=== p3
config: mode=link present=n/a render-delay-ms=0.0 colorspace=p3 min-duration=0.0 link-hz=120.0 present-every=1 latency=2.0 drawables=2 at-time=false hud=true window=small drawable=4112x2658 scaler=true picture=video source=counter display-mode=keep
latency (presented_time - callback_time, shown rows, non-zero presented, first 2.0 s excluded): n=355 p50=41.517 p99=41.596 max=49.884 ms
```
Colorspace has no visible effect on timing.

**Extra checks I ran:**
- `--mode vsync --runloop main --slots-csv ...`, 5 s: `wrongThread=0`, and the CSV was written with 590 rows.
- Bad flag combinations: `--mode vsync` with the default `--source index` prints `FATAL: --mode vsync needs --source counter`. `--present at-slot --source counter` without `--mode vsync` prints `FATAL: --present at-slot and --render-delay-ms need --mode vsync`.

## (c) Small window, composited: not the gate condition
One 20 s run per row. 120 Hz, AC power, Low Power Mode off. Load average at exit was 2.4 to 3.4 on every run, and 10 ffmpeg processes were running at the start.

| mode | present | render delay | latency p50 / p99 (ms) | presented − slot p50 / p99 (ms) | in-band % | max glitches per 15 s | `nextDrawable` wait p99 (ms) |
|---|---|---|---|---|---|---|---|
| vsync | plain | 0 | 24.91 / 24.95 | 16.650 / 16.666 | 99.628 | 4 | 0.195 |
| vsync | at-slot | 0 | 24.93 / 24.96 (n=325, see note) | 16.648 / 16.669 (n=325) | 98.462 | 5 | 0.180 |
| vsync | plain | 4 ms | 20.78 / 29.14 | 16.657 / 24.999 | 47.491 | 511 | 0.160 |
| vsync | at-slot | 4 ms | 20.45 / 29.13 | 16.655 / 24.998 | 56.279 | 410 | 0.138 |
| link | n/a | n/a | 41.53 / 41.61 | -0.018 / -0.000 | 99.720 | 2 | n/a |

Notes:
- **At-slot, delay 0:** 753 of the 1199 shown rows had `presented_time` 0 (the display skipped them), so only 325 steady rows were measured.
- **Slot time in vsync:** "slot time" is the tick's `targetTimestamp`. Presentation landed about one refresh (16.65 ms) after it, and 25 ms after it in the delay-4 runs, so the picture does not reach the glass at the slot time the Pacer reserved.
- **Delay 4:** with a 4 ms delay the frames alternate between 25.00 ms and 8.33 ms apart, so the 16.68 ms cadence breaks. The delayed pick likely misses the vsync that the 0 ms runs hit, so the drawable lands one refresh later, in a 25 ms / 8.33 ms alternation. I did not investigate this.
- **Latency vs link:** the vsync p50 is about 17 ms lower than link's 41.5 ms, but the picture is one refresh after the reserved slot time. The 20 ms p99 bar is met in these runs only by the delay-0 plain run, at 24.95 ms, which is above 20 ms.

## (d) Not finished
- Full-screen runs: not run by instruction. The gate condition is not measured.
- `native120` and `native5994` display-mode runs: not run by instruction. No 59.94 Hz vsync data.
- Only one 20 s run per configuration. The at-slot delay-0 run had 753 zero-`presentedTime` rows, which is odd. I did not repeat the run, so I cannot say whether that is a fluke or a real at-slot effect.
- The 4 ms-delay 25 ms / 8.33 ms alternation is unexplained.
- `--mode vsync --source index` is not implemented; the probe exits with a FATAL.
- "Tick time" for `--render-delay-ms` is the tick-entry host time. `link.timestamp` and `targetTimestamp` are other readings of "tick time" that I did not use. Entry-based timing is used, via `mach_absolute_time` + `mach_wait_until`.
- The first vsync attempt was invalid (the shell passed `--present at-slot` as one word). It was caught and the whole set re-run; no number above comes from that attempt.

## (e) SDK headers vs the brief
- No header text contradicts the brief.
- `CADisplayLink.h`: `+displayLinkWithTarget:selector:` is `API_UNAVAILABLE(macos)`; the NSScreen method is the only route on macOS. `NSScreen.h` line 141 has `displayLinkWithTarget:selector:` with the Swift name `displayLink(target:selector:)`, as the brief says.
- `CAMetalLayer.h`: `allowsNextDrawableTimeout` is YES by default and `nextDrawable` times out after 1 s. `colorspace` nil means no colour matching.
- Measured contradiction of an assumption in the brief: `targetTimestamp` is not the glass time of a drawable taken and presented in that tick. In vsync mode `presentedTime` landed about 16.65 ms after `targetTimestamp` (p50) with plain present, 25 ms with a 4 ms delay.
- The brief's "latency p50 near 49.9 ms in a small window" does not match this machine's 120 Hz state; 41.5 ms is the expected 120 Hz value.