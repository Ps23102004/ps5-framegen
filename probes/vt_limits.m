// vt_limits: what the VideoToolbox frame processors and the MetalFX spatial scaler allow on this Mac,
// plus scaler timing on real decoded frames.
// Usage: vt_limits [video] [start s] [outdir]     (no video = limits only, no timing)
// Build: clang -fobjc-arc -O2 vt_limits.m -o vt_limits -framework Foundation -framework VideoToolbox -framework CoreMedia
//        -framework CoreVideo -framework Metal -framework MetalFX -framework QuartzCore -framework AVFoundation -framework CoreImage -framework IOSurface
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

#define FRAMES 300
#define WARM 10
typedef struct { int w,h; } Sz;
static const Sz SIZES[]={{960,540},{1280,720},{1600,900},{1728,972},{1920,1080},{2560,1440},{3456,1944},{3840,2160},{4096,2160},{7680,4320}};
static const int NSIZES=sizeof(SIZES)/sizeof(SIZES[0]);

static double now(void){ return CACurrentMediaTime()*1000.0; }
static const char *cc(uint32_t f){ static char b[8][16]; static int i; char *s=b[i++&7];
  if(f<0x20000000) snprintf(s,16,"%u",f); else { uint32_t be=CFSwapInt32HostToBig(f); snprintf(s,16,"%.4s",(char*)&be);} return s; }
static void fmts(NSArray<NSNumber*>*a){ if(!a.count)printf(" (none)"); for(NSNumber*n in a) printf(" %s",cc(n.unsignedIntValue)); printf("\n"); }
static NSArray *pfList(NSDictionary*d){ id pf=d[(id)kCVPixelBufferPixelFormatTypeKey]; return [pf isKindOfClass:[NSArray class]]?pf:(pf?@[pf]:@[]); }
static void attrs(const char*l,NSDictionary*d){
  printf("    %s: width=%s height=%s keys=[%s] formats:",l,[[d[(id)kCVPixelBufferWidthKey] description] UTF8String]?:"-",
    [[d[(id)kCVPixelBufferHeightKey] description] UTF8String]?:"-",[[d.allKeys componentsJoinedByString:@","] UTF8String]); fmts(pfList(d)); }
static void describe(id<VTFrameProcessorConfiguration> cfg){
  printf("    frameSupportedPixelFormats:"); fmts(cfg.frameSupportedPixelFormats);
  attrs("sourcePixelBufferAttributes",cfg.sourcePixelBufferAttributes); attrs("destinationPixelBufferAttributes",cfg.destinationPixelBufferAttributes);
  if([cfg respondsToSelector:@selector(previousFrameCount)]) printf("    previousFrameCount=%ld\n",(long)cfg.previousFrameCount);
  if([cfg respondsToSelector:@selector(nextFrameCount)]) printf("    nextFrameCount=%ld\n",(long)cfg.nextFrameCount); }
static void dims(Class c){ for(NSString*n in @[@"minimumDimensions",@"maximumDimensions"]){ SEL s=NSSelectorFromString(n);
  if([c respondsToSelector:s]){ CMVideoDimensions d=((CMVideoDimensions(*)(id,SEL))objc_msgSend)(c,s); printf("  %s: %dx%d\n",n.UTF8String,d.width,d.height);}
  else printf("  %s: not exposed by this class\n",n.UTF8String);} }
static BOOL tryStart(id<VTFrameProcessorConfiguration> cfg){ VTFrameProcessor*p=[VTFrameProcessor new]; NSError*e=nil; double a=now();
  BOOL ok=[p startSessionWithConfiguration:cfg error:&e]; // seen on macOS 27.2.1: can return YES and still fill in an error, so both are printed
  printf("    startSession: returned %s, error %s, %.0f ms -> %s%s%s\n",ok?"YES":"NO",e?"SET":"nil",now()-a,(ok&&!e)?"USABLE":"NOT USABLE",e?"  ":"",
    e?[[e.description stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]:"");
  if(ok)[p endSession]; return ok&&!e; }
// Which of SIZES give a non-nil configuration (creation only; header-declared limits are printed separately where they exist).
static void sizeSweep(id(^mk)(int,int)){ printf("  config creation by size:");
  for(int i=0;i<NSIZES;i++){ id c=nil; @try{c=mk(SIZES[i].w,SIZES[i].h);}@catch(id e){c=nil;} printf(" %dx%d=%s",SIZES[i].w,SIZES[i].h,c?"ok":"nil"); } printf("\n"); }
static void stats(const char *label,NSArray<NSNumber*>*ms){
  NSArray *s=[ms sortedArrayUsingSelector:@selector(compare:)]; long c=s.count; if(!c){printf("  %s: no samples\n",label);return;}
  double (^q)(double)=^double(double x){return [s[MIN(c-1,(long)(x*c))] doubleValue];};
  double sum=0; long slow=0; for(NSNumber*n in s){sum+=n.doubleValue; if(n.doubleValue>1.5*q(.5))slow++;}
  printf("  %s: n=%ld  p5 %.2f  p25 %.2f  p50 %.2f  p75 %.2f  p95 %.2f  p99 %.2f  max %.2f  mean %.2f ms  (>1.5x p50: %.1f%%)\n",
    label,c,q(.05),q(.25),q(.5),q(.75),q(.95),q(.99),[s.lastObject doubleValue],sum/c,100.0*slow/c); }

static CVPixelBufferRef newBuf(NSDictionary *attrs,int w,int h){
  NSMutableDictionary *a=[attrs mutableCopy]; a[(id)kCVPixelBufferWidthKey]=@(w); a[(id)kCVPixelBufferHeightKey]=@(h);
  if(!a[(id)kCVPixelBufferIOSurfacePropertiesKey]) a[(id)kCVPixelBufferIOSurfacePropertiesKey]=@{};
  CVPixelBufferRef b=NULL; CVPixelBufferCreate(NULL,w,h,[pfList(a)[0] unsignedIntValue],(__bridge CFDictionaryRef)a,&b); return b; }
static void savejpg(CVPixelBufferRef b,NSString *p){ static CIContext *c; if(!c)c=[CIContext context];
  CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  [c writeJPEGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:b] toURL:[NSURL fileURLWithPath:p] colorSpace:cs options:@{} error:nil]; CGColorSpaceRelease(cs); }
// Real frames: decode the recording from `start`, keep every 2nd decoded frame (30 real fps inside 60 Hz), scale to WxH in the
// pixel format `attrs` asks for, hand `count` of them to blk. Decode + scale are outside whatever blk times.
static void eachFrame(NSString*path,double start,long count,int W,int H,NSDictionary*attrs,void(^blk)(long,CVPixelBufferRef,CMTime)){
  NSError*err=nil; AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetReader *r=[AVAssetReader assetReaderWithAsset:asset error:&err]; if(!r){printf("  reader failed: %s\n",err.description.UTF8String);return;}
  r.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(start,600),kCMTimePositiveInfinity);
  AVAssetReaderTrackOutput *o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[asset tracksWithMediaType:AVMediaTypeVideo][0]
    outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
  o.alwaysCopiesSampleData=NO; [r addOutput:o]; [r startReading];
  VTPixelTransferSessionRef xfer; VTPixelTransferSessionCreate(NULL,&xfer);
  long n=0,k=0; CMSampleBufferRef sb;
  while(k<count && (sb=[o copyNextSampleBuffer])){
    if((n++)%2){CFRelease(sb);continue;}
    CVPixelBufferRef cur=newBuf(attrs,W,H); OSStatus st=VTPixelTransferSessionTransferImage(xfer,CMSampleBufferGetImageBuffer(sb),cur);
    if(st&&k==0) printf("  pixel transfer status %d\n",(int)st);
    @autoreleasepool{ blk(k++,cur,CMSampleBufferGetPresentationTimeStamp(sb)); }
    CVPixelBufferRelease(cur); CFRelease(sb);
  }
  [r cancelReading]; VTPixelTransferSessionInvalidate(xfer); CFRelease(xfer);
  if(k<count) printf("  only %ld of %ld frames decoded\n",k,count);
}

// 3a. VTLowLatencySuperResolutionScaler: FRAMES timed frames after WARM warm-up frames, destination buffers reused from a ring of 4.
static void timeLLSR(NSString*path,double start,NSString*out,int W,int H,float f){
  VTLowLatencySuperResolutionScalerConfiguration*cfg=nil;
  @try{cfg=[[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:W frameHeight:H scaleFactor:f];}@catch(id e){}
  if(!cfg){printf("LLSR %dx%d x%.3f: configuration nil\n",W,H,f);return;}
  NSDictionary*da=cfg.destinationPixelBufferAttributes;
  int OW=[da[(id)kCVPixelBufferWidthKey] intValue]?:(int)lroundf(W*f), OH=[da[(id)kCVPixelBufferHeightKey] intValue]?:(int)lroundf(H*f);
  VTFrameProcessor*p=[VTFrameProcessor new]; NSError*err=nil; double a=now();
  if(![p startSessionWithConfiguration:cfg error:&err]){printf("LLSR %dx%d x%.3f: startSession FAILED %s\n",W,H,f,err.description.UTF8String);return;}
  printf("LLSR %dx%d x%.3f -> %dx%d (dest attrs width/height %s; src fmt %s, dst fmt %s), startSession %.0f ms\n",W,H,f,OW,OH,
    da[(id)kCVPixelBufferWidthKey]?"given by API":"NOT given, computed as round(src*factor)",
    cc([pfList(cfg.sourcePixelBufferAttributes)[0] unsignedIntValue]),cc([pfList(da)[0] unsignedIntValue]),now()-a);
  CVPixelBufferRef ringA[4],*ring=ringA; for(int i=0;i<4;i++) ring[i]=newBuf(da,OW,OH);
  NSMutableArray<NSNumber*>*ms=[NSMutableArray array]; __block long fails=0; __block double first=0;
  eachFrame(path,start,FRAMES+WARM,W,H,cfg.sourcePixelBufferAttributes,^(long k,CVPixelBufferRef src,CMTime t){
    CVPixelBufferRef dst=ring[k&3];
    VTLowLatencySuperResolutionScalerParameters*pr=[[VTLowLatencySuperResolutionScalerParameters alloc]
      initWithSourceFrame:[[VTFrameProcessorFrame alloc] initWithBuffer:src presentationTimeStamp:t]
      destinationFrame:[[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:t]];
    NSError*e=nil; double a=now(); BOOL ok=[p processWithParameters:pr error:&e]; double d=now()-a;
    if(k==0)first=d;
    if(!ok){ if(fails++<2) printf("  process error: %s\n",e.description.UTF8String); }
    else if(k>=WARM)[ms addObject:@(d)];
    if(ok&&k==WARM+150&&out) savejpg(dst,[out stringByAppendingPathComponent:[NSString stringWithFormat:@"llsr_%dx%d_to_%dx%d.jpg",W,H,OW,OH]]);
  });
  [p endSession]; for(int i=0;i<4;i++) CVPixelBufferRelease(ring[i]);
  printf("  first call %.2f ms, fails %ld, output buffer %zux%zu\n",first,fails,(size_t)OW,(size_t)OH);
  stats("processWithParameters wall",ms);
}

// 3b. MetalFX spatial scaler: BGRA8 in (IOSurface texture from the decoded frame) -> private BGRA8 out. One command buffer per frame.
static void timeMFX(NSString*path,double start,NSString*out,int W,int H,int OW,int OH){
  id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q=[dev newCommandQueue];
  MTLFXSpatialScalerDescriptor*d=[MTLFXSpatialScalerDescriptor new]; d.inputWidth=W; d.inputHeight=H; d.outputWidth=OW; d.outputHeight=OH;
  d.colorTextureFormat=MTLPixelFormatBGRA8Unorm; d.outputTextureFormat=MTLPixelFormatBGRA8Unorm; d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
  double a=now(); id<MTLFXSpatialScaler> sc=[d newSpatialScalerWithDevice:dev];
  if(!sc){printf("MetalFX %dx%d -> %dx%d: scaler nil\n",W,H,OW,OH);return;}
  printf("MetalFX spatial %dx%d -> %dx%d BGRA8Unorm perceptual, scaler created in %.0f ms, colorTextureUsage=0x%lx outputTextureUsage=0x%lx\n",
    W,H,OW,OH,now()-a,(unsigned long)sc.colorTextureUsage,(unsigned long)sc.outputTextureUsage);
  MTLTextureDescriptor*od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:OW height:OH mipmapped:NO];
  od.storageMode=MTLStorageModePrivate; od.usage=sc.outputTextureUsage|MTLTextureUsageShaderRead; id<MTLTexture> outT=[dev newTextureWithDescriptor:od];
  NSDictionary*bgra=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
  NSMutableArray<NSNumber*>*gpu=[NSMutableArray array],*wall=[NSMutableArray array],*kern=[NSMutableArray array];
  eachFrame(path,start,FRAMES+WARM,W,H,bgra,^(long k,CVPixelBufferRef src,CMTime t){
    MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage=sc.colorTextureUsage|MTLTextureUsageShaderRead;
    id<MTLTexture> inT=[dev newTextureWithDescriptor:td iosurface:CVPixelBufferGetIOSurface(src) plane:0];
    sc.colorTexture=inT; sc.inputContentWidth=W; sc.inputContentHeight=H; sc.outputTexture=outT;
    id<MTLCommandBuffer> cb=[q commandBuffer]; [sc encodeToCommandBuffer:cb];
    double a=now(); [cb commit]; [cb waitUntilCompleted]; double w=now()-a;
    if(cb.status!=MTLCommandBufferStatusCompleted){ printf("  command buffer status %lu %s\n",(unsigned long)cb.status,cb.error.description.UTF8String); return; }
    if(k>=WARM){ [gpu addObject:@((cb.GPUEndTime-cb.GPUStartTime)*1000.0)]; [wall addObject:@(w)]; [kern addObject:@((cb.kernelEndTime-cb.kernelStartTime)*1000.0)]; }
    if(k==WARM+150&&out){ // read back one frame for a visual check (not timed)
      CVPixelBufferRef rb=newBuf(bgra,OW,OH); MTLTextureDescriptor*rd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:OW height:OH mipmapped:NO];
      id<MTLTexture> rt=[dev newTextureWithDescriptor:rd iosurface:CVPixelBufferGetIOSurface(rb) plane:0];
      id<MTLCommandBuffer> c2=[q commandBuffer]; id<MTLBlitCommandEncoder> be=[c2 blitCommandEncoder];
      [be copyFromTexture:outT sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(OW,OH,1) toTexture:rt destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
      [be endEncoding]; [c2 commit]; [c2 waitUntilCompleted];
      savejpg(rb,[out stringByAppendingPathComponent:[NSString stringWithFormat:@"metalfx_%dx%d_to_%dx%d.jpg",W,H,OW,OH]]);
      savejpg(src,[out stringByAppendingPathComponent:[NSString stringWithFormat:@"scaler_source_%dx%d.jpg",W,H]]); CVPixelBufferRelease(rb); }
  });
  stats("GPU time (GPUEndTime-GPUStartTime)",gpu); stats("kernel time (kernelEnd-kernelStart)",kern); stats("commit -> waitUntilCompleted wall",wall);
}

int main(int argc,char**argv){@autoreleasepool{
  setvbuf(stdout,NULL,_IOLBF,0);
  NSProcessInfo*pi=NSProcessInfo.processInfo; id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
  printf("# vt_limits  host: %s, %s, GPU: %s\n\n",pi.operatingSystemVersionString.UTF8String,[[NSDate date] description].UTF8String,dev.name.UTF8String);

  // ---- 1. VTLowLatencyFrameInterpolation
  printf("== VTLowLatencyFrameInterpolation\n  isSupported: %d\n",VTLowLatencyFrameInterpolationConfiguration.isSupported);
  dims([VTLowLatencyFrameInterpolationConfiguration class]);
  for(int s=1;s<=4;s++) printf("  spatialScaleFactor %d: maximumDimension=%ld maximumPixelCount=%ld\n",s,
    (long)[VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:s],(long)[VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:s]);
  printf("  temporal only, numberOfInterpolatedFrames=1:\n"); sizeSweep(^id(int w,int h){return [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];});
  printf("  temporal + spatialScaleFactor=2:\n"); sizeSweep(^id(int w,int h){return [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h spatialScaleFactor:2];});
  printf("  temporal only, startSession by size (config creation does not validate size, startSession does):\n");
  for(int i=0;i<NSIZES;i++){ printf("   %dx%d",SIZES[i].w,SIZES[i].h); tryStart([[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:SIZES[i].w frameHeight:SIZES[i].h numberOfInterpolatedFrames:1]); }
  printf("  temporal + spatial x2, startSession by size:\n"); Sz S2[]={{640,360},{960,540},{1280,720},{1728,972}};
  for(int i=0;i<4;i++){ printf("   %dx%d",S2[i].w,S2[i].h); tryStart([[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:S2[i].w frameHeight:S2[i].h spatialScaleFactor:2]); }
  for(int n=1;n<=4;n++){ VTLowLatencyFrameInterpolationConfiguration*c=[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1920 frameHeight:1080 numberOfInterpolatedFrames:n];
    printf("  1920x1080 numberOfInterpolatedFrames=%d: config %s\n",n,c?"created":"nil"); if(c&&n==1){describe(c);tryStart(c);} }
  { VTLowLatencyFrameInterpolationConfiguration*c=[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1728 frameHeight:972 spatialScaleFactor:2];
    printf("  1728x972 spatialScaleFactor=2 (would give 3456x1944): config %s\n",c?"created":"nil"); if(c){describe(c);tryStart(c);} }

  // ---- 2. VTLowLatencySuperResolutionScaler
  printf("\n== VTLowLatencySuperResolutionScaler\n  isSupported: %d\n",VTLowLatencySuperResolutionScalerConfiguration.isSupported);
  dims([VTLowLatencySuperResolutionScalerConfiguration class]);
  NSArray<NSNumber*>*allF=VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors;
  printf("  supportedScaleFactors (class): %s\n",[[allF componentsJoinedByString:@" "] UTF8String]);
  for(NSNumber*f in allF) printf("  scale %.3f: maximumDimension=%ld maximumPixelCount=%ld\n",f.floatValue,
    (long)[VTLowLatencySuperResolutionScalerConfiguration maximumDimensionForSpatialScaleFactor:f.floatValue],(long)[VTLowLatencySuperResolutionScalerConfiguration maximumPixelCountForSpatialScaleFactor:f.floatValue]);
  for(int i=0;i<NSIZES;i++) printf("  supportedScaleFactorsForFrameWidth:%d frameHeight:%d -> [%s]\n",SIZES[i].w,SIZES[i].h,
    [[[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:SIZES[i].w frameHeight:SIZES[i].h] componentsJoinedByString:@" "] UTF8String]);
  NSArray<NSNumber*>*f1080=[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:1920 frameHeight:1080];
  if(!f1080.count) printf("  1920x1080: NO supported scale factor -> configuration cannot be created\n");
  for(NSNumber*f in f1080){ VTLowLatencySuperResolutionScalerConfiguration*c=nil; @try{c=[[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:1920 frameHeight:1080 scaleFactor:f.floatValue];}@catch(id e){}
    printf("  1920x1080 x%.3f: config %s\n",f.floatValue,c?"created":"nil"); if(c){describe(c);tryStart(c);} }

  // ---- 3. VTSuperResolutionScaler (the non-low-latency one; may need a model download: we only read the status, never download)
  printf("\n== VTSuperResolutionScaler\n  isSupported: %d\n",VTSuperResolutionScalerConfiguration.isSupported);
  dims([VTSuperResolutionScalerConfiguration class]);
  NSArray<NSNumber*>*srF=VTSuperResolutionScalerConfiguration.supportedScaleFactors;
  printf("  supportedScaleFactors: %s\n  supportedRevisions: %s  defaultRevision: %ld\n",[[srF componentsJoinedByString:@" "] UTF8String],
    VTSuperResolutionScalerConfiguration.supportedRevisions.description.UTF8String,(long)VTSuperResolutionScalerConfiguration.defaultRevision);
  for(NSNumber*f in (srF.count?srF:@[@2])){ NSInteger sf=f.integerValue;
    printf("  scaleFactor %ld, inputType video:\n",(long)sf);
    sizeSweep(^id(int w,int h){return [[VTSuperResolutionScalerConfiguration alloc] initWithFrameWidth:w frameHeight:h scaleFactor:sf inputType:VTSuperResolutionScalerConfigurationInputTypeVideo usePrecomputedFlow:NO qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal revision:VTSuperResolutionScalerConfiguration.defaultRevision];});
    VTSuperResolutionScalerConfiguration*c=[[VTSuperResolutionScalerConfiguration alloc] initWithFrameWidth:1920 frameHeight:1080 scaleFactor:sf inputType:VTSuperResolutionScalerConfigurationInputTypeVideo usePrecomputedFlow:NO qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal revision:VTSuperResolutionScalerConfiguration.defaultRevision];
    printf("  1920x1080 x%ld: config %s\n",(long)sf,c?"created":"nil");
    if(c){ describe(c); printf("    configurationModelStatus=%ld (0 download required, 1 downloading, 2 ready)  configurationModelPercentageAvailable=%.2f\n",(long)c.configurationModelStatus,c.configurationModelPercentageAvailable);
      if(c.configurationModelStatus==VTSuperResolutionScalerConfigurationModelStatusReady) tryStart(c); else printf("    startSession: skipped (model not ready; probe never downloads)\n"); } }

  // ---- 4-6. FrameRateConversion, OpticalFlow, MotionBlur (offline-quality processors)
  printf("\n== VTFrameRateConversion\n  isSupported: %d\n",VTFrameRateConversionConfiguration.isSupported); dims([VTFrameRateConversionConfiguration class]);
  printf("  supportedRevisions: %s  defaultRevision: %ld\n",VTFrameRateConversionConfiguration.supportedRevisions.description.UTF8String,(long)VTFrameRateConversionConfiguration.defaultRevision);
  for(int qp=1;qp<=2;qp++){ printf("  qualityPrioritization=%d (1 normal, 2 quality):\n",qp);
    id(^mk)(int,int)=^id(int w,int h){return [[VTFrameRateConversionConfiguration alloc] initWithFrameWidth:w frameHeight:h usePrecomputedFlow:NO qualityPrioritization:qp revision:VTFrameRateConversionConfiguration.defaultRevision];};
    sizeSweep(mk); id<VTFrameProcessorConfiguration> c=mk(1920,1080); printf("  1920x1080: config %s\n",c?"created":"nil"); if(c){describe(c);tryStart(c);} }

  printf("\n== VTOpticalFlow\n  isSupported: %d\n",VTOpticalFlowConfiguration.isSupported); dims([VTOpticalFlowConfiguration class]);
  printf("  supportedRevisions: %s  defaultRevision: %ld\n",VTOpticalFlowConfiguration.supportedRevisions.description.UTF8String,(long)VTOpticalFlowConfiguration.defaultRevision);
  for(int qp=1;qp<=2;qp++){ printf("  qualityPrioritization=%d (1 normal, 2 quality):\n",qp);
    id(^mk)(int,int)=^id(int w,int h){return [[VTOpticalFlowConfiguration alloc] initWithFrameWidth:w frameHeight:h qualityPrioritization:qp revision:VTOpticalFlowConfiguration.defaultRevision];};
    sizeSweep(mk); id<VTFrameProcessorConfiguration> c=mk(1920,1080); printf("  1920x1080: config %s\n",c?"created":"nil"); if(c){describe(c);tryStart(c);} }

  printf("\n== VTMotionBlur\n  isSupported: %d\n",VTMotionBlurConfiguration.isSupported); dims([VTMotionBlurConfiguration class]);
  printf("  supportedRevisions: %s  defaultRevision: %ld\n",VTMotionBlurConfiguration.supportedRevisions.description.UTF8String,(long)VTMotionBlurConfiguration.defaultRevision);
  for(int qp=1;qp<=2;qp++){ printf("  qualityPrioritization=%d (1 normal, 2 quality):\n",qp);
    id(^mk)(int,int)=^id(int w,int h){return [[VTMotionBlurConfiguration alloc] initWithFrameWidth:w frameHeight:h usePrecomputedFlow:NO qualityPrioritization:qp revision:VTMotionBlurConfiguration.defaultRevision];};
    sizeSweep(mk); id<VTFrameProcessorConfiguration> c=mk(1920,1080); printf("  1920x1080: config %s\n",c?"created":"nil"); if(c){describe(c);tryStart(c);} }

  // ---- 7. VTTemporalNoiseFilter
  printf("\n== VTTemporalNoiseFilter\n  isSupported: %d\n",VTTemporalNoiseFilterConfiguration.isSupported); dims([VTTemporalNoiseFilterConfiguration class]);
  NSArray<NSNumber*>*tnf=VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats; printf("  supportedSourcePixelFormats:"); fmts(tnf);
  { OSType pf=tnf.count?tnf[0].unsignedIntValue:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    id(^mk)(int,int)=^id(int w,int h){return [[VTTemporalNoiseFilterConfiguration alloc] initWithFrameWidth:w frameHeight:h sourcePixelFormat:pf];};
    sizeSweep(mk); id<VTFrameProcessorConfiguration> c=mk(1920,1080); printf("  1920x1080 (%s): config %s\n",cc(pf),c?"created":"nil"); if(c){describe(c);tryStart(c);} }

  // ---- MetalFX spatial scaler
  printf("\n== MetalFX MTLFXSpatialScaler on %s\n  supportsDevice: %d  supportsMetal4FX: %d\n",dev.name.UTF8String,[MTLFXSpatialScalerDescriptor supportsDevice:dev],[MTLFXSpatialScalerDescriptor supportsMetal4FX:dev]);
  printf("  color processing modes in header: perceptual(0) linear(1) hdr(2)\n  scaler creation 1920x1080 -> 3456x1944 by format (same in/out format) x mode [perceptual linear hdr]:\n");
  struct { MTLPixelFormat f; const char*n; } F[]={{MTLPixelFormatBGRA8Unorm,"BGRA8Unorm"},{MTLPixelFormatBGRA8Unorm_sRGB,"BGRA8Unorm_sRGB"},{MTLPixelFormatRGBA8Unorm,"RGBA8Unorm"},{MTLPixelFormatRGBA8Unorm_sRGB,"RGBA8Unorm_sRGB"},
    {MTLPixelFormatRGB10A2Unorm,"RGB10A2Unorm"},{MTLPixelFormatBGR10A2Unorm,"BGR10A2Unorm"},{MTLPixelFormatBGR10_XR,"BGR10_XR"},{MTLPixelFormatRG11B10Float,"RG11B10Float"},{MTLPixelFormatRGBA16Float,"RGBA16Float"},{MTLPixelFormatRGBA32Float,"RGBA32Float"},{MTLPixelFormatR8Unorm,"R8Unorm"},{MTLPixelFormatRG8Unorm,"RG8Unorm"}};
  for(int i=0;i<(int)(sizeof(F)/sizeof(F[0]));i++){ printf("    %-16s",F[i].n);
    for(int m=0;m<3;m++){ id s=nil; @try{ MTLFXSpatialScalerDescriptor*d=[MTLFXSpatialScalerDescriptor new]; d.inputWidth=1920; d.inputHeight=1080; d.outputWidth=3456; d.outputHeight=1944;
        d.colorTextureFormat=F[i].f; d.outputTextureFormat=F[i].f; d.colorProcessingMode=m; s=[d newSpatialScalerWithDevice:dev]; }@catch(id e){ s=nil; }
      printf(" %s",s?"ok ":"nil"); } printf("\n"); }
  printf("  scaler creation by size (BGRA8Unorm, perceptual):");
  int R[][4]={{1920,1080,1920,1080},{1920,1080,3456,1944},{1728,972,3456,1944},{1600,900,3456,1944},{1280,720,3456,1944},{960,540,3456,1944},{1920,1080,3840,2160},{1920,1080,7680,4320},{3456,1944,1920,1080}};
  for(int i=0;i<(int)(sizeof(R)/sizeof(R[0]));i++){ id s=nil; @try{ MTLFXSpatialScalerDescriptor*d=[MTLFXSpatialScalerDescriptor new]; d.inputWidth=R[i][0]; d.inputHeight=R[i][1]; d.outputWidth=R[i][2]; d.outputHeight=R[i][3];
      d.colorTextureFormat=MTLPixelFormatBGRA8Unorm; d.outputTextureFormat=MTLPixelFormatBGRA8Unorm; s=[d newSpatialScalerWithDevice:dev]; }@catch(id e){ s=nil; }
    printf(" %dx%d->%dx%d=%s",R[i][0],R[i][1],R[i][2],R[i][3],s?"ok":"nil"); } printf("\n");

  if(argc<3){ printf("\n(no video given: timing skipped)\n"); return 0; }
  NSString*path=@(argv[1]); double start=atof(argv[2]); NSString*out=argc>3?@(argv[3]):nil;
  printf("\n== TIMING (UNDER LOAD: six unrelated ffmpeg jobs were using the CPU). %d timed frames after %d warm-up, real frames from %s at %.0f s, every 2nd decoded frame\n",FRAMES,WARM,path.lastPathComponent.UTF8String,start);
  printf("-- 3a. VTLowLatencySuperResolutionScaler (wanted: 1920x1080 -> 3456x1944 = 1.8x; timed at every size/factor the API accepts)\n");
  Sz T[]={{1920,1080},{1728,972},{1600,900},{1280,720},{960,540}};
  for(int i=0;i<5;i++){ NSArray<NSNumber*>*fs=[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:T[i].w frameHeight:T[i].h];
    if(!fs.count) printf("LLSR %dx%d: no supported scale factors, not timed\n",T[i].w,T[i].h);
    for(NSNumber*f in fs) timeLLSR(path,start,out,T[i].w,T[i].h,f.floatValue); }
  printf("-- 3b. MetalFX spatial scaler -> 3456x1944\n");
  for(int i=0;i<4;i++) timeMFX(path,start,out,T[i].w,T[i].h,3456,1944);
}}
