/* ABI v2 / XNU 1035 V10: two-client full-frame DMA test, no CPU fallback.
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
#define CAP (12u*1024u*1024u)
#define W 1080u
#define H 2160u
#define PITCH 4352u
#define N 16u
#define C 2u
static mach_timebase_info_data_t tb;
struct client {io_connect_t c;mach_vm_address_t sa,da;mach_vm_size_t sn,dn;uint64_t seq,t;};
static uint64_t ns(uint64_t t){return (uint64_t)((__uint128_t)t*tb.numer/tb.denom);}
static int cmp(const void *a,const void *b){uint64_t x=*(const uint64_t *)a,y=*(const uint64_t *)b;return (x>y)-(x<y);}
static void stats(const char *s,uint64_t *a,unsigned n){qsort(a,n,sizeof(*a),cmp);printf("%s ms: p50=%.3f p95=%.3f p99=%.3f max=%.3f\n",s,a[(n-1)*50/100]/1e6,a[(n-1)*95/100]/1e6,a[(n-1)*99/100]/1e6,a[n-1]/1e6);}
static uint32_t pat(uint32_t i,uint32_t j){uint32_t v=i*0x9e3779b9U+j*0x85ebca6bU;return (v^(v>>16))|0xff000000U;}
static void status(void){
    uint32_t stage=0;size_t z=sizeof(stage);
    if(!sysctlbyname("kern.whyred_gpu_cp_state",&stage,&z,NULL,0))printf("CP_STAGE=%u\n",stage);
    char irq[128]={0};z=sizeof(irq);
    if(!sysctlbyname("kern.whyred_gpu_irq_state",irq,&z,NULL,0))printf("IRQ: %s\n",irq);
}
static int open_client(io_service_t s,struct client *p){
    kern_return_t k=IOServiceOpen(s,mach_task_self(),0,&p->c);if(k){fprintf(stderr,"open failed: 0x%x\n",k);return 0;}
    uint64_t info[4]={0};uint32_t n=4;
    k=IOConnectCallScalarMethod(p->c,0,NULL,0,info,&n);
    if(k||n!=4||info[0]!=2||info[1]<W||info[2]<H||info[3]!=CAP)return 0;
    k=IOConnectMapMemory64(p->c,1,mach_task_self(),&p->sa,&p->sn,1);
    if(k||!p->sa||p->sn!=CAP)return 0;
    k=IOConnectMapMemory64(p->c,2,mach_task_self(),&p->da,&p->dn,1);
    if(k||!p->da||p->dn!=CAP)return 0;
    return 1;
}
int main(void){
    status();
    uint32_t stage=0;size_t z=sizeof(stage);
    if(sysctlbyname("kern.whyred_gpu_cp_state",&stage,&z,NULL,0)||stage!=12){fprintf(stderr,"DIRECT_SERVICE_NOT_READY\n");return 2;}
    io_service_t s=IOServiceGetMatchingService(MACH_PORT_NULL,IOServiceMatching("WhyredA509DirectService"));
    if(!s){fprintf(stderr,"DIRECT_SERVICE_ABSENT\n");return 3;}
    struct client c[C]={0};int ret=1;
    for(unsigned b=0;b<C;b++)if(!open_client(s,&c[b])){fprintf(stderr,"CLIENT_OPEN_FAILED slot=%u\n",b);goto out;}
    io_connect_t third=0;
    if(!IOServiceOpen(s,mach_task_self(),0,&third)){IOServiceClose(third);fprintf(stderr,"UNEXPECTED_THIRD_CLIENT\n");goto out;}
    uint64_t bad[3]={W,H,1},badseq=0;uint32_t n=1;
    if(!IOConnectCallScalarMethod(c[0].c,1,bad,3,&badseq,&n)){fprintf(stderr,"INVALID_GEOMETRY_ACCEPTED\n");goto out;}
    mach_timebase_info(&tb);
    uint64_t submit[N*C],gpu[N*C],e2e[N*C],previous=0;
    for(uint32_t j=0;j<N;j++){
        for(unsigned b=0;b<C;b++){
            uint32_t *src=(uint32_t *)(uintptr_t)c[b].sa;
            volatile uint32_t *dst=(volatile uint32_t *)(uintptr_t)c[b].da;
            for(uint32_t i=0;i<CAP/4;i++){src[i]=pat(i,j*C+b);dst[i]=0xa5a5a5a5U;}
        }
        __asm__ volatile("dsb sy" ::: "memory");
        // Submit BOTH before waiting. Reverse submission order on alternating rounds.
        for(unsigned order=0;order<C;order++){
            unsigned b=(order+j)%C;uint64_t in[3]={W,H,PITCH};n=1;
            c[b].t=mach_absolute_time();c[b].seq=0;
            kern_return_t k=IOConnectCallScalarMethod(c[b].c,1,in,3,&c[b].seq,&n);
            submit[j*C+b]=ns(mach_absolute_time()-c[b].t);
            if(k||n!=1||!c[b].seq||c[b].seq==previous){fprintf(stderr,"SUBMIT_FAILED slot=%u job=%u 0x%x\n",b,j,k);goto out;}
            previous=c[b].seq;
        }
        uint64_t wrong[2]={0};n=2;
        if(!IOConnectCallScalarMethod(c[0].c,2,&c[1].seq,1,wrong,&n)){fprintf(stderr,"CROSS_CONTEXT_FENCE_ACCEPTED\n");goto out;}
        for(unsigned b=0;b<C;b++){
            uint64_t result[2]={0};n=2;
            kern_return_t k=IOConnectCallScalarMethod(c[b].c,3,&c[b].seq,1,result,&n);
            e2e[j*C+b]=ns(mach_absolute_time()-c[b].t);
            if(k||n!=2||result[0]!=3){fprintf(stderr,"WAIT_FAILED slot=%u job=%u 0x%x state=%llu\n",b,j,k,(unsigned long long)result[0]);goto out;}
            gpu[j*C+b]=result[1];
        }
        __asm__ volatile("dsb sy" ::: "memory");
        for(unsigned b=0;b<C;b++){
            volatile uint32_t *dst=(volatile uint32_t *)(uintptr_t)c[b].da;
            for(uint32_t i=0;i<CAP/4;i++){
                int active=i<(PITCH/4)*H && i%(PITCH/4)<W;
                if(dst[i]!=(active?pat(i,j*C+b):0xa5a5a5a5U)){fprintf(stderr,"MISMATCH slot=%u job=%u dword=%u\n",b,j,i);goto out;}
            }
        }
    }
    stats("Submit",submit,N*C);stats("GPU execution",gpu,N*C);stats("Submit-to-observed-fence (includes queue)",e2e,N*C);
    puts("A509_DUAL_CONTEXT_PASS: 32 full-frame jobs, both contexts and padding checked");ret=0;
out:
    for(unsigned b=0;b<C;b++){
        if(c[b].da)IOConnectUnmapMemory64(c[b].c,2,mach_task_self(),c[b].da);
        if(c[b].sa)IOConnectUnmapMemory64(c[b].c,1,mach_task_self(),c[b].sa);
        if(c[b].c)IOServiceClose(c[b].c);
    }
    IOObjectRelease(s);status();return ret;
}
