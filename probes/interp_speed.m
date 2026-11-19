// Experiment 1: Apple low-latency frame interpolation speed on recorded GTA 6 gameplay.
// Decodes the recording, scales to 1920x1080, keeps every 2nd frame (30 real fps inside 60 Hz),
// interpolates the midpoint between each pair, times each call. Usage: interp_speed <video> <start s> <seconds> <outdir>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
static double now(){ return CACurrentMediaTime()*1000.0; }
static CVPixelBufferRef newBuf(NSDictionary *attrs,int w,int h){
  NSMutableDictionary *a=[attrs mutableCopy]; a[(id)kCVPixelBufferWidthKey]=@(w); a[(id)kCVPixelBufferHeightKey]=@(h);
  CVPixelBufferRef b=NULL; CVPixelBufferCreate(NULL,w,h,[a[(id)kCVPixelBufferPixelFormatTypeKey] isKindOfClass:[NSArray class]]?[a[(id)kCVPixelBufferPixelFormatTypeKey][0] unsignedIntValue]:[a[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue],(__bridge CFDictionaryRef)a,&b); return b; }
static void savejpg(CVPixelBufferRef b,NSString *p){ CIImage *i=[CIImage imageWithCVPixelBuffer:b]; CIContext *c=[CIContext context];
  [c writeJPEGRepresentationOfImage:i toURL:[NSURL fileURLWithPath:p] colorSpace:CGColorSpaceCreateWithName(kCGColorSpaceSRGB) options:@{} error:nil]; }
int main(int argc,char**argv){@autoreleasepool{
  NSString *path=@(argv[1]); double start=atof(argv[2]), secs=atof(argv[3]); NSString *out=@(argv[4]);
  int W=1920,H=1080;
  VTLowLatencyFrameInterpolationConfiguration *cfg=[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:W frameHeight:H numberOfInterpolatedFrames:1];
  if(!cfg){printf("config failed\n");return 1;}
  printf("pixel formats:"); for(NSNumber *n in cfg.frameSupportedPixelFormats){uint32_t f=n.unsignedIntValue; printf(" %.4s",(char*)&(uint32_t){CFSwapInt32HostToBig(f)});} printf("\n");
  VTFrameProcessor *proc=[VTFrameProcessor new]; NSError *err=nil;
  if(![proc startSessionWithConfiguration:cfg error:&err]){printf("start failed %s\n",err.description.UTF8String);return 1;}
  AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetReader *r=[AVAssetReader assetReaderWithAsset:asset error:&err];
  r.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(start,600),CMTimeMakeWithSeconds(secs,600));
  AVAssetTrack *vt=[asset tracksWithMediaType:AVMediaTypeVideo][0];
  AVAssetReaderTrackOutput *o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
  o.alwaysCopiesSampleData=NO; [r addOutput:o]; [r startReading];
  VTPixelTransferSessionRef xfer; VTPixelTransferSessionCreate(NULL,&xfer);
  NSMutableArray<NSNumber*> *ms=[NSMutableArray array];
  CVPixelBufferRef prev=NULL; CMTime prevT; long n=0, fails=0; double t0=now();
  CMSampleBufferRef sb;
  while((sb=[o copyNextSampleBuffer])){
    if((n++)%2){CFRelease(sb);continue;}  // 30 real frames: each game frame arrives twice in the 60 Hz signal
    CVPixelBufferRef src=CMSampleBufferGetImageBuffer(sb); CMTime t=CMSampleBufferGetPresentationTimeStamp(sb);
    CVPixelBufferRef cur=newBuf(cfg.sourcePixelBufferAttributes,W,H); VTPixelTransferSessionTransferImage(xfer,src,cur); CFRelease(sb);
    if(prev){
      CVPixelBufferRef dst=newBuf(cfg.destinationPixelBufferAttributes,W,H);
      VTFrameProcessorFrame *fs=[[VTFrameProcessorFrame alloc] initWithBuffer:cur presentationTimeStamp:t];
      VTFrameProcessorFrame *fp=[[VTFrameProcessorFrame alloc] initWithBuffer:prev presentationTimeStamp:prevT];
      VTFrameProcessorFrame *fd=[[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMultiplyByRatio(CMTimeAdd(t,prevT),1,2)];
      VTLowLatencyFrameInterpolationParameters *p=[[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fs previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
      double a=now(); BOOL ok=[proc processWithParameters:p error:&err]; double d=now()-a;
      if(ok)[ms addObject:@(d)]; else if(fails++<3) printf("process error: %s\n",err.description.UTF8String);
      if(ms.count==300){ savejpg(prev,[out stringByAppendingPathComponent:@"a_prev.jpg"]); savejpg(dst,[out stringByAppendingPathComponent:@"b_generated.jpg"]); savejpg(cur,[out stringByAppendingPathComponent:@"c_next.jpg"]); }
      CVPixelBufferRelease(dst); CVPixelBufferRelease(prev);
    }
    prev=cur; prevT=t;
  }
  if(prev)CVPixelBufferRelease(prev);
  [proc endSession];
  NSArray *s=[ms sortedArrayUsingSelector:@selector(compare:)]; long c=s.count;
  if(!c){printf("no frames processed (fails %ld)\n",fails);return 1;}
  double (^q)(double)=^double(double x){return [s[MIN(c-1,(long)(x*c))] doubleValue];};
  long m=MIN(c,1800); double f=0,l=0; for(long i=0;i<m;i++){f+=[ms[i] doubleValue]; l+=[ms[c-1-i] doubleValue];}
  printf("interpolated %ld frames at %dx%d in %.0f s wall (fails %ld)\n",c,W,H,(now()-t0)/1000,fails);
  printf("ms per frame: p50 %.2f  p95 %.2f  p99 %.2f  max %.2f\n",q(.5),q(.95),q(.99),[s.lastObject doubleValue]);
  printf("drift: first-minute mean %.2f ms, last-minute mean %.2f ms\n",f/m,l/m);
}}
