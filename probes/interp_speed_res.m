// interp_speed_res: VTLowLatencyFrameInterpolation midpoint speed at a chosen resolution, on recorded GTA 6 gameplay.
// Same method as interp_speed.m: decode, scale to WxH, keep every 2nd decoded frame (30 real fps inside 60 Hz),
// interpolate the midpoint of each pair, time each processWithParameters call.
// Usage: interp_speed_res <video> <start s> <seconds> <width> <height> [pace_ms=0] [reuse=0]
//   pace_ms: 0 = back to back (as interp_speed.m). 33.37 = one call per real game frame, like the live app (GPU may clock down between calls).
//   reuse:   0 = fresh pixel buffers every frame (as interp_speed.m). 1 = buffers recycled through CVPixelBufferPools, like the live app.
// Build: clang -fobjc-arc -O2 -Wno-deprecated-declarations interp_speed_res.m -o interp_speed_res -framework Foundation -framework AVFoundation
//        -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
static double now(void){ return CACurrentMediaTime()*1000.0; }
static CVPixelBufferRef newBuf(NSDictionary *attrs,int w,int h,CVPixelBufferPoolRef pool){
  CVPixelBufferRef b=NULL; if(pool){ CVPixelBufferPoolCreatePixelBuffer(NULL,pool,&b); return b; }
  NSMutableDictionary *a=[attrs mutableCopy]; a[(id)kCVPixelBufferWidthKey]=@(w); a[(id)kCVPixelBufferHeightKey]=@(h);
  id pf=a[(id)kCVPixelBufferPixelFormatTypeKey]; CVPixelBufferCreate(NULL,w,h,[pf isKindOfClass:[NSArray class]]?[pf[0] unsignedIntValue]:[pf unsignedIntValue],(__bridge CFDictionaryRef)a,&b); return b; }
static CVPixelBufferPoolRef newPool(NSDictionary*attrs,int w,int h){ NSMutableDictionary *a=[attrs mutableCopy]; a[(id)kCVPixelBufferWidthKey]=@(w); a[(id)kCVPixelBufferHeightKey]=@(h);
  id pf=a[(id)kCVPixelBufferPixelFormatTypeKey]; if([pf isKindOfClass:[NSArray class]]) a[(id)kCVPixelBufferPixelFormatTypeKey]=pf[0];
  CVPixelBufferPoolRef p=NULL; CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)a,&p); return p; }
int main(int argc,char**argv){@autoreleasepool{
  if(argc<6){printf("usage: interp_speed_res <video> <start s> <seconds> <width> <height> [pace_ms] [reuse]\n");return 2;}
  NSString *path=@(argv[1]); double start=atof(argv[2]), secs=atof(argv[3]); int W=atoi(argv[4]),H=atoi(argv[5]);
  double pace=argc>6?atof(argv[6]):0; BOOL reuse=argc>7&&atoi(argv[7]);
  VTLowLatencyFrameInterpolationConfiguration *cfg=[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:W frameHeight:H numberOfInterpolatedFrames:1];
  if(!cfg){printf("config failed\n");return 1;}
  VTFrameProcessor *proc=[VTFrameProcessor new]; NSError *err=nil; double s0=now();
  BOOL started=[proc startSessionWithConfiguration:cfg error:&err];
  if(!started||err){printf("%dx%d start failed (returned %d): %s\n",W,H,started,err.description.UTF8String);return 1;} // returns YES with an error for unsupported sizes
  printf("== %dx%d (%d px, %.2fx of 1080p)  pace %.2f ms  buffers %s  startSession %.0f ms\n",W,H,W*H,W*H/2073600.0,pace,reuse?"pooled":"fresh",now()-s0);
  AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetReader *r=[AVAssetReader assetReaderWithAsset:asset error:&err];
  r.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(start,600),CMTimeMakeWithSeconds(secs,600));
  AVAssetReaderTrackOutput *o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[asset tracksWithMediaType:AVMediaTypeVideo][0] outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
  o.alwaysCopiesSampleData=NO; [r addOutput:o]; [r startReading];
  VTPixelTransferSessionRef xfer; VTPixelTransferSessionCreate(NULL,&xfer);
  CVPixelBufferPoolRef sp=reuse?newPool(cfg.sourcePixelBufferAttributes,W,H):NULL, dp=reuse?newPool(cfg.destinationPixelBufferAttributes,W,H):NULL;
  NSMutableArray<NSNumber*> *ms=[NSMutableArray array];
  CVPixelBufferRef prev=NULL; CMTime prevT=kCMTimeZero; long n=0, fails=0; double t0=now(), next=now();
  CMSampleBufferRef sb;
  while((sb=[o copyNextSampleBuffer])){ @autoreleasepool{
    if((n++)%2){CFRelease(sb);continue;}  // 30 real frames: each game frame arrives twice in the 60 Hz signal
    CVPixelBufferRef src=CMSampleBufferGetImageBuffer(sb); CMTime t=CMSampleBufferGetPresentationTimeStamp(sb);
    CVPixelBufferRef cur=newBuf(cfg.sourcePixelBufferAttributes,W,H,sp); VTPixelTransferSessionTransferImage(xfer,src,cur); CFRelease(sb);
    if(prev){
      CVPixelBufferRef dst=newBuf(cfg.destinationPixelBufferAttributes,W,H,dp);
      VTFrameProcessorFrame *fs=[[VTFrameProcessorFrame alloc] initWithBuffer:cur presentationTimeStamp:t];
      VTFrameProcessorFrame *fp=[[VTFrameProcessorFrame alloc] initWithBuffer:prev presentationTimeStamp:prevT];
      VTFrameProcessorFrame *fd=[[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMultiplyByRatio(CMTimeAdd(t,prevT),1,2)];
      VTLowLatencyFrameInterpolationParameters *p=[[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fs previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
      if(pace>0){ next+=pace; double w=next-now(); if(w>0) usleep((useconds_t)(w*1000)); else next=now(); }
      double a=now(); BOOL ok=[proc processWithParameters:p error:&err]; double d=now()-a;
      if(ok)[ms addObject:@(d)]; else if(fails++<3) printf("process error: %s\n",err.description.UTF8String);
      CVPixelBufferRelease(dst); CVPixelBufferRelease(prev);
    }
    prev=cur; prevT=t;
  }}
  if(prev)CVPixelBufferRelease(prev);
  [proc endSession];
  NSArray *s=[ms sortedArrayUsingSelector:@selector(compare:)]; long c=s.count;
  if(!c){printf("no frames processed (fails %ld)\n",fails);return 1;}
  double (^q)(double)=^double(double x){return [s[MIN(c-1,(long)(x*c))] doubleValue];};
  double sum=0; long slow=0; for(NSNumber*v in s){sum+=v.doubleValue; if(v.doubleValue>1.5*q(.5))slow++;}
  printf("interpolated %ld frames in %.0f s wall (fails %ld)\n",c,(now()-t0)/1000,fails);
  printf("ms per frame: p5 %.2f  p25 %.2f  p50 %.2f  p75 %.2f  p95 %.2f  p99 %.2f  max %.2f  mean %.2f  (>1.5x p50: %.1f%%)\n",q(.05),q(.25),q(.5),q(.75),q(.95),q(.99),[s.lastObject doubleValue],sum/c,100.0*slow/c);
  // Medians of 10 consecutive chunks in time order: a step in this row = something else took the GPU for part of the run.
  printf("p50 per tenth of the run (time order):"); for(int i=0;i<10;i++){ NSArray*ch=[[ms subarrayWithRange:NSMakeRange(c*i/10,c*(i+1)/10-c*i/10)] sortedArrayUsingSelector:@selector(compare:)]; if(ch.count)printf(" %.2f",[ch[ch.count/2] doubleValue]); } printf("\n");
  // Coarse histogram relative to p50: two separated humps = bimodal.
  double e[]={0.8,0.9,1.1,1.25,1.5,2,3}; long h[8]={0}; for(NSNumber*v in s){ double x=v.doubleValue/q(.5); int b=0; while(b<7&&x>=e[b])b++; h[b]++; }
  printf("histogram (x p50): <0.8:%ld 0.8-0.9:%ld 0.9-1.1:%ld 1.1-1.25:%ld 1.25-1.5:%ld 1.5-2:%ld 2-3:%ld >=3:%ld\n",h[0],h[1],h[2],h[3],h[4],h[5],h[6],h[7]);
}}
