#import "DLCapture.h"
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>
#include <cstdio>
static std::vector<uint8_t> g_frame; static int g_w=0,g_h=0,g_rb=0; static bool g_v210=false; static int g_count=0;
int main(){ @autoreleasepool {
  DLCapture* c=[[DLCapture alloc] initWithDeviceIndex:0];
  if(!c){printf("no device\n");return 0;}
  c.frameHandler=^(int w,int h,int rb,BOOL v210,const void* base,int len,int m,int r){
    g_w=w;g_h=h;g_rb=rb;g_v210=v210; g_frame.assign((const uint8_t*)base,(const uint8_t*)base+len); g_count++; };
  [c start];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:4.0]];
  [c stop];
  if(g_frame.empty()||!g_v210){printf("no v210 frame (count=%d, v210=%d)\n",g_count,g_v210);return 0;}
  printf("frame %dx%d rb=%d\n",g_w,g_h,g_rb);
  const double ia=123.0*M_PI/180.0, ca=cos(ia), sa=sin(ia);
  const int NB=90; const double maxR=0.45; std::vector<long> hist(NB,0); long total=0;
  const uint32_t* base=(const uint32_t*)g_frame.data(); int wpr=g_rb/4;
  for(int y=0;y<g_h;y++){ const uint32_t* row=base+y*wpr; int groups=g_w/6;
    for(int gi=0;gi<groups;gi++){ const uint32_t* w4=row+gi*4; uint32_t w0=w4[0],w1=w4[1],w2=w4[2],w3=w4[3];
      double pr[3][2]={ {(double)(w0&0x3ff),(double)((w0>>20)&0x3ff)}, {(double)((w1>>10)&0x3ff),(double)(w2&0x3ff)}, {(double)((w2>>20)&0x3ff),(double)((w3>>10)&0x3ff)} };
      for(int k=0;k<3;k++){ double Cb=(pr[k][0]-512.0)/896.0, Cr=(pr[k][1]-512.0)/896.0;
        double along=Cb*ca+Cr*sa, perp=Cb*(-sa)+Cr*ca;
        if(fabs(perp)<0.03 && along>0.03 && along<maxR){ int b=(int)(along/maxR*NB); if(b>=0&&b<NB){hist[b]++;total++;} } } } }
  long mx=std::max(1L,*std::max_element(hist.begin(),hist.end()));
  printf("samples near I-line: %ld\n",total);
  for(int b=0;b<NB;b++){ double r=(b+0.5)/NB*maxR; int bar=(int)(hist[b]*60/mx);
    printf("r=%.3f sat%%=%2.0f %6ld %s\n", r, r/0.5*100, hist[b], std::string(bar,'#').c_str()); }
} return 0; }
