// quality_trio: motion-quality samples for Apple's VTLowLatencyFrameInterpolation on recorded gameplay.
// Build: clang -fobjc-arc -O2 quality_trio.m -o quality_trio -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreImage -framework QuartzCore -framework CoreGraphics -framework ImageIO
// Run:  ./quality_trio <video> <outdir> <t1 seconds> [t2 ...]      (env QT_THR=<luma diff threshold>, default 1.5)
// For each timestamp: decode forward, keep only DISTINCT game frames (luma diff against the last distinct frame,
// webcam corner masked, no reliance on frame parity), scale to 1920x1080 420v, interpolate the midpoint of every
// consecutive distinct pair (3 warm-up pairs first, like a running app), and save the first pair after warm-up whose
// frames are exactly one game frame (2 video frames) apart:
//   <outdir>/motion_<n>/a_prev.jpg  b_generated.jpg  c_next.jpg  ab_blend.jpg (naive 50/50 of prev and next)  info.txt
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
enum { W=1920, H=1080, STEP=8, WARM=3 };
static double now(void){ return CACurrentMediaTime()*1000.0; }
static CVPixelBufferRef newBuf(NSDictionary *attrs){
  NSMutableDictionary *a=[attrs mutableCopy]; a[(id)kCVPixelBufferWidthKey]=@(W); a[(id)kCVPixelBufferHeightKey]=@(H);
  id f=a[(id)kCVPixelBufferPixelFormatTypeKey]; uint32_t fmt=[f isKindOfClass:[NSArray class]]?[f[0] unsignedIntValue]:[f unsignedIntValue];
  CVPixelBufferRef b=NULL; CVPixelBufferCreate(NULL,W,H,fmt,(__bridge CFDictionaryRef)a,&b); return b; }
static void savejpg(CIContext *c,CIImage *i,NSString *p){
  CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  [c writeJPEGRepresentationOfImage:i toURL:[NSURL fileURLWithPath:p] colorSpace:cs options:@{(id)kCGImageDestinationLossyCompressionQuality:@0.92} error:nil]; CGColorSpaceRelease(cs); }
// Point-sample the luma plane every STEP pixels, skipping the webcam overlay (measured: x >= 86.8 %, y >= 76.9 %).
// ponytail: mask is hard-coded for this OBS recording; drop it for clean capture.
static size_t sampleLuma(CVPixelBufferRef pb,uint8_t *out){
  CVPixelBufferLockBaseAddress(pb,kCVPixelBufferLock_ReadOnly);
  const uint8_t *base=CVPixelBufferGetBaseAddressOfPlane(pb,0); size_t bpr=CVPixelBufferGetBytesPerRowOfPlane(pb,0),w=CVPixelBufferGetWidthOfPlane(pb,0),h=CVPixelBufferGetHeightOfPlane(pb,0),n=0;
  for(size_t y=0;y<h;y+=STEP) for(size_t x=0;x<w;x+=STEP){ if(x>=w*0.86 && y>=h*0.76) continue; out[n++]=base[y*bpr+x]; }
  CVPixelBufferUnlockBaseAddress(pb,kCVPixelBufferLock_ReadOnly); return n; }
static double meanAbs(const uint8_t *a,const uint8_t *b,size_t n){ uint64_t s=0; for(size_t i=0;i<n;i++) s+=abs((int)a[i]-(int)b[i]); return n?(double)s/n:0; }

int main(int argc,char**argv){@autoreleasepool{
  if(argc<4){printf("usage: quality_trio <video> <outdir> <t1> [t2 ...]\n");return 2;}
  NSString *path=@(argv[1]), *outRoot=@(argv[2]); double thr=getenv("QT_THR")?atof(getenv("QT_THR")):1.5;
  AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetTrack *vt=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject; if(!vt){printf("no video track\n");return 1;}
  double fps=vt.nominalFrameRate; CIContext *ci=[CIContext context];
  VTPixelTransferSessionRef xfer; VTPixelTransferSessionCreate(NULL,&xfer);
  static uint8_t curS[1<<19], refS[1<<19];
  for(int k=3;k<argc;k++){ @autoreleasepool{
    double start=atof(argv[k]); NSString *dir=[outRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"motion_%d",k-2]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    FILE *info=fopen([dir stringByAppendingPathComponent:@"info.txt"].UTF8String,"w");
    #define LOG(...) do{ printf(__VA_ARGS__); if(info) fprintf(info,__VA_ARGS__); }while(0)
    LOG("motion_%d: %s @ %.3f s, distinct threshold %.2f\n",k-2,path.lastPathComponent.UTF8String,start,thr);
    // Fresh session per timestamp so one sample cannot leak temporal state into the next.
    VTLowLatencyFrameInterpolationConfiguration *cfg=[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:W frameHeight:H numberOfInterpolatedFrames:1];
    VTFrameProcessor *proc=[VTFrameProcessor new]; NSError *err=nil; double s0=now();
    if(!cfg || ![proc startSessionWithConfiguration:cfg error:&err]){LOG("session start failed: %s\n",err.description.UTF8String); if(info)fclose(info); continue;}
    LOG("startSession %.0f ms\n",now()-s0);
    AVAssetReader *r=[AVAssetReader assetReaderWithAsset:asset error:&err];
    r.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(start,60000),CMTimeMakeWithSeconds(4,60000));
    AVAssetReaderTrackOutput *o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
    o.alwaysCopiesSampleData=NO; [r addOutput:o]; [r startReading];
    CVPixelBufferRef prev=NULL; CMTime prevT=kCMTimeZero; int pairs=0; BOOL haveRef=NO, saved=NO; CMSampleBufferRef sb;
    while(!saved && (sb=[o copyNextSampleBuffer])){
      CVPixelBufferRef src=CMSampleBufferGetImageBuffer(sb); CMTime t=CMSampleBufferGetPresentationTimeStamp(sb);
      size_t n=sampleLuma(src,curS); double d=haveRef?meanAbs(curS,refS,n):-1;
      if(haveRef && d<=thr){ LOG("  pts %.4f diff %6.2f duplicate\n",CMTimeGetSeconds(t),d); CFRelease(sb); continue; }
      memcpy(refS,curS,n); haveRef=YES;
      CVPixelBufferRef cur=newBuf(cfg.sourcePixelBufferAttributes); VTPixelTransferSessionTransferImage(xfer,src,cur); CFRelease(sb);
      if(!prev){ LOG("  pts %.4f first frame\n",CMTimeGetSeconds(t)); }
      else{
        double gap=CMTimeGetSeconds(CMTimeSubtract(t,prevT))*fps;
        CVPixelBufferRef dst=newBuf(cfg.destinationPixelBufferAttributes);
        // Experiment knob: QT_PREFILL=1 copies the next frame into the destination first, to tell whether the green
        // fringe at the frame border is pixels the processor never writes (prefill shows through) or zeros it writes.
        if(getenv("QT_PREFILL")) VTPixelTransferSessionTransferImage(xfer,cur,dst);
        VTFrameProcessorFrame *fs=[[VTFrameProcessorFrame alloc] initWithBuffer:cur presentationTimeStamp:t];
        VTFrameProcessorFrame *fp=[[VTFrameProcessorFrame alloc] initWithBuffer:prev presentationTimeStamp:prevT];
        VTFrameProcessorFrame *fd=[[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMultiplyByRatio(CMTimeAdd(t,prevT),1,2)];
        VTLowLatencyFrameInterpolationParameters *p=[[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fs previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
        double a=now(); BOOL ok=[proc processWithParameters:p error:&err]; double ms=now()-a; pairs++;
        BOOL take=ok && pairs>WARM && gap>1.5 && gap<2.5;
        LOG("  pts %.4f diff %6.2f NEW  gap %.1f frames, interpolate %s %.1f ms%s\n",CMTimeGetSeconds(t),d,gap,ok?"ok":"FAILED",ms,take?"  <- saved":"");
        if(!ok) LOG("    error: %s\n",err.description.UTF8String);
        if(take){
          CIImage *ia=[CIImage imageWithCVPixelBuffer:prev], *ic=[CIImage imageWithCVPixelBuffer:cur];
          savejpg(ci,ia,[dir stringByAppendingPathComponent:@"a_prev.jpg"]);
          savejpg(ci,[CIImage imageWithCVPixelBuffer:dst],[dir stringByAppendingPathComponent:@"b_generated.jpg"]);
          savejpg(ci,ic,[dir stringByAppendingPathComponent:@"c_next.jpg"]);
          savejpg(ci,[ia imageByApplyingFilter:@"CIDissolveTransition" withInputParameters:@{kCIInputTargetImageKey:ic,kCIInputTimeKey:@0.5}],[dir stringByAppendingPathComponent:@"ab_blend.jpg"]);
          saved=YES;
        }
        CVPixelBufferRelease(dst); CVPixelBufferRelease(prev);
      }
      prev=cur; prevT=t;
    }
    if(prev)CVPixelBufferRelease(prev);
    [r cancelReading]; [proc endSession];
    if(!saved) LOG("  NOTHING SAVED: no clean distinct pair within 4 s (stall, static picture or threshold too high)\n");
    if(info)fclose(info);
  }}
}}
