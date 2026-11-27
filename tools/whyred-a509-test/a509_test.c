/* ABI v1 / XNU 1034: exercise actual GPU copies, not a CPU fallback.
 * Build for iOS arm64 with the iPhoneOS SDK. Run as root.
 * No private address, unvalidated PM4 or MMIO is passed to the kernel.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __has_include(<IOKit/IOKitLib.h>)
#include <IOKit/IOKitLib.h>
#else
/* Stable userspace IOKit C ABI, for SDKs without public IOKit headers. */
typedef mach_port_t io_object_t, io_service_t, io_connect_t;
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOObjectRelease(io_object_t);
extern kern_return_t IOServiceClose(io_connect_t);
extern kern_return_t IOConnectCallScalarMethod(io_connect_t,uint32_t,const uint64_t *,uint32_t,uint64_t *,uint32_t *);
extern kern_return_t IOConnectMapMemory64(io_connect_t,uint32_t,task_port_t,mach_vm_address_t *,mach_vm_size_t *,uint32_t);
extern kern_return_t IOConnectUnmapMemory64(io_connect_t,uint32_t,task_port_t,mach_vm_address_t);
#endif
#define BYTES 262144u
#define N 256u
#define ACTIVE (256u*240u*4u)
static mach_timebase_info_data_t tb;
static uint64_t ns(uint64_t t){return (uint64_t)((__uint128_t)t*tb.numer/tb.denom);}
static int cmp(const void *a,const void *b){uint64_t x=*(const uint64_t *)a,y=*(const uint64_t *)b;return (x>y)-(x<y);}
static void stats(const char *s,uint64_t *a,unsigned n){qsort(a,n,sizeof(*a),cmp);printf("%s us: p50=%.2f p95=%.2f p99=%.2f max=%.2f\n",s,a[(n-1)*50/100]/1000.,a[(n-1)*95/100]/1000.,a[(n-1)*99/100]/1000.,a[n-1]/1000.);}
static void state(void){uint32_t s=0;size_t n=sizeof(s);if(!sysctlbyname("kern.whyred_gpu_cp_state",&s,&n,NULL,0))printf("CP_STAGE=%u\n",s);else perror("kern.whyred_gpu_cp_state");}
static uint32_t pattern(uint32_t i,uint32_t j){uint32_t v=i*0x9e3779b9U+j*0x85ebca6bU;v^=v>>16;return v|0xff000000U;}
int main(void){
    state();
    io_service_t s=IOServiceGetMatchingService(MACH_PORT_NULL,IOServiceMatching("WhyredA509Service"));
    if(!s){fprintf(stderr,"GPU service absent: boot selftest has not passed\n");return 2;}
    io_connect_t c=0; kern_return_t k=IOServiceOpen(s,mach_task_self(),0,&c);IOObjectRelease(s);
    if(k){fprintf(stderr,"IOServiceOpen: 0x%x (root required)\n",k);return 3;}
    int ret=1;mach_vm_address_t sa=0,da=0;mach_vm_size_t sn=0,dn=0;
    uint64_t info[4]={0};uint32_t n=4;
    k=IOConnectCallScalarMethod(c,0,NULL,0,info,&n);
    if(k||n!=4||info[0]!=1||info[1]!=256||info[2]!=240||info[3]!=BYTES){fprintf(stderr,"ABI query failed: 0x%x\n",k);goto out;}
    k=IOConnectMapMemory64(c,1,mach_task_self(),&sa,&sn,1); // kIOMapAnywhere
    if(k||!sa||sn<BYTES){fprintf(stderr,"src map failed: 0x%x\n",k);goto out;}
    k=IOConnectMapMemory64(c,2,mach_task_self(),&da,&dn,1);
    if(k||!da||dn<BYTES){fprintf(stderr,"dst map failed: 0x%x\n",k);goto out;}
    uint64_t invalid[3]={257,1,1024},o[2]={0};n=2;
    if(!IOConnectCallScalarMethod(c,1,invalid,3,o,&n)){fprintf(stderr,"INVALID_GEOMETRY_ACCEPTED\n");goto out;}
    mach_timebase_info(&tb);
    uint64_t gpu[N],e2e[N];uint32_t last=0;
    uint32_t *src=(uint32_t *)(uintptr_t)sa,*dst=(uint32_t *)(uintptr_t)da;
    for(unsigned j=0;j<N;j++){
        // Change every pixel every submission; validate reuse and ring wrap.
        for(unsigned i=0;i<ACTIVE/4;i++)src[i]=pattern(i,j);
        memset(dst,0xa5,BYTES);
        uint64_t in[3]={256,240,1024};n=2;
        uint64_t t=mach_absolute_time();k=IOConnectCallScalarMethod(c,1,in,3,o,&n);e2e[j]=ns(mach_absolute_time()-t);
        if(k||n!=2||!o[0]||(uint32_t)o[0]==last){fprintf(stderr,"submit %u failed: 0x%x\n",j,k);goto out;}
        last=(uint32_t)o[0];gpu[j]=o[1];
        for (unsigned i=ACTIVE;i<BYTES;i++) if (((uint8_t *)dst)[i]!=0xa5) {fprintf(stderr,"CLIENT_TAIL_CHANGED iteration=%u\n",j);goto out;}
        if(memcmp(src,dst,ACTIVE)){fprintf(stderr,"PIXEL_MISMATCH iteration=%u\n",j);goto out;}
    }
    stats("GPU fence",gpu,N);stats("IOKit + staging + GPU",e2e,N);
    puts("A509_USER_COPY_PASS: 256 jobs, all pixels compared");ret=0;
out:
    if(da)IOConnectUnmapMemory64(c,2,mach_task_self(),da);
    if(sa)IOConnectUnmapMemory64(c,1,mach_task_self(),sa);
    IOServiceClose(c);state();return ret;
}
