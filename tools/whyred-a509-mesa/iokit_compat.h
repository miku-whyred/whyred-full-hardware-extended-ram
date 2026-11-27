/* Public IOKit C ABI subset; XNU 8796 IOReturn.h. For SDKs lacking headers. */
#ifndef WHYRED_A509_IOKIT_COMPAT_H
#define WHYRED_A509_IOKIT_COMPAT_H
#if __has_include(<IOKit/IOKitLib.h>)
#include <IOKit/IOKitLib.h>
#else
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
typedef mach_port_t io_service_t,io_connect_t,io_object_t;
#define kIOMapAnywhere 1U
#define kIOReturnNoMemory ((kern_return_t)0xe00002bd)
#define kIOReturnBadArgument ((kern_return_t)0xe00002c2)
#define kIOReturnUnsupported ((kern_return_t)0xe00002c7)
#define kIOReturnBusy ((kern_return_t)0xe00002d5)
#define kIOReturnTimeout ((kern_return_t)0xe00002d6)
#define kIOReturnNotFound ((kern_return_t)0xe00002f0)
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern io_service_t IOServiceGetMatchingService(mach_port_t,CFDictionaryRef);
extern kern_return_t IOServiceOpen(io_service_t,task_port_t,uint32_t,io_connect_t *);
extern kern_return_t IOObjectRelease(io_object_t);
extern kern_return_t IOConnectCallStructMethod(io_connect_t,uint32_t,const void *,size_t,void *,size_t *);
extern kern_return_t IOConnectMapMemory64(io_connect_t,uint32_t,task_port_t,mach_vm_address_t *,mach_vm_size_t *,uint32_t);
extern kern_return_t IOConnectUnmapMemory64(io_connect_t,uint32_t,task_port_t,mach_vm_address_t);
#endif
#endif
