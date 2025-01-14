/*	CFMachPort.c
	Copyright (c) 1998-2019, Apple Inc. and the Swift project authors
 
	Portions Copyright (c) 2014-2019, Apple Inc. and the Swift project authors
	Licensed under Apache License v2.0 with Runtime Library Exception
	See http://swift.org/LICENSE.txt for license information
	See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
	Responsibility: Michael LeHew
*/

#include <CoreFoundation/CFMachPort.h>
#include <CoreFoundation/CFRunLoop.h>
#include <CoreFoundation/CFArray.h>
#include <dispatch/dispatch.h>
#if __has_include(<dispatch/private.h>)
#include <dispatch/private.h>
#endif
#include <mach/mach.h>
#include <dlfcn.h>
#include <stdio.h>
#include <CoreFoundation/GSCFInternal.h>
#include <CoreFoundation/CFRuntime_Internal.h>
#include "CFMachPort_Lifetime.h"


// This queue is used for the cancel/event handler for dead name notification.
static dispatch_queue_t _CFMachPortQueue() {
    static volatile dispatch_queue_t __CFMachPortQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t dqattr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_BACKGROUND, 0);
        __CFMachPortQueue = dispatch_queue_create("com.apple.CFMachPort", dqattr);
    });
    return __CFMachPortQueue;
}

enum {
    kCFMachPortStateReady = 0,
    kCFMachPortStateInvalidating = 1,
    kCFMachPortStateInvalid = 2,
    kCFMachPortStateDeallocating = 3
};

struct __CFMachPort {
    CFRuntimeBase _base;
    int32_t _state;
    mach_port_t _port;                          /* immutable */
    dispatch_source_t _dsrc;                    /* protected by _lock */
    CFMachPortInvalidationCallBack _icallout;   /* protected by _lock */
    CFRunLoopSourceRef _source;                 /* immutable, once created */
    CFMachPortCallBack _callout;                /* immutable */
    CFMachPortContext _context;                 /* immutable */
    CFLock_t _lock;
    const void *(*retain)(const void *info); // use these to store the real callbacks
    void        (*release)(const void *info);
};

/* Bit 1 in the base reserved bits is used for has-receive-ref state */
/* Bit 2 in the base reserved bits is used for has-send-ref state */

CF_INLINE Boolean __CFMachPortHasReceive(CFMachPortRef mp) {
    return __CFRuntimeGetFlag(mp, 1);
}

CF_INLINE void __CFMachPortSetHasReceive(CFMachPortRef mp) {
    __CFRuntimeSetFlag(mp, 1, true);
}

CF_INLINE Boolean __CFMachPortHasSend(CFMachPortRef mp) {
    return __CFRuntimeGetFlag(mp, 2);
}

CF_INLINE void __CFMachPortSetHasSend(CFMachPortRef mp) {
    __CFRuntimeSetFlag(mp, 2, true);
}

CF_INLINE Boolean __CFMachPortIsValid(CFMachPortRef mp) {
    return kCFMachPortStateReady == mp->_state;
}


void _CFMachPortInstallNotifyPort(CFRunLoopRef rl, CFStringRef mode) {
}

static Boolean __CFMachPortEqual(CFTypeRef cf1, CFTypeRef cf2) {
    CFMachPortRef mp1 = (CFMachPortRef)cf1;
    CFMachPortRef mp2 = (CFMachPortRef)cf2;
    return (mp1->_port == mp2->_port);
}

static CFHashCode __CFMachPortHash(CFTypeRef cf) {
    CFMachPortRef mp = (CFMachPortRef)cf;
    return (CFHashCode)mp->_port;
}

static CFStringRef __CFMachPortCopyDescription(CFTypeRef cf) {
    CFMachPortRef mp = (CFMachPortRef)cf;
    CFStringRef contextDesc = NULL;
    if (NULL != mp->_context.info && NULL != mp->_context.copyDescription) {
        contextDesc = mp->_context.copyDescription(mp->_context.info);
    }
    if (NULL == contextDesc) {
        contextDesc = CFStringCreateWithFormat(kCFAllocatorSystemDefault, NULL, CFSTR("<CFMachPort context %p>"), mp->_context.info);
    }
    Dl_info info;
    void *addr = mp->_callout;
    const char *name = (dladdr(addr, &info) && info.dli_saddr == addr && info.dli_sname) ? info.dli_sname : "???";
    CFStringRef result = CFStringCreateWithFormat(kCFAllocatorSystemDefault, NULL, CFSTR("<CFMachPort %p [%p]>{valid = %s, port = %x, source = %p, callout = %s (%p), context = %@}"), cf, CFGetAllocator(mp), (__CFMachPortIsValid(mp) ? "Yes" : "No"), mp->_port, mp->_source, name, addr, contextDesc);
    if (NULL != contextDesc) {
        CFRelease(contextDesc);
    }
    return result;
}

// Only call with mp->_lock locked
CF_INLINE void __CFMachPortInvalidateLocked(CFRunLoopSourceRef source, CFMachPortRef mp) {
    CFMachPortInvalidationCallBack cb = mp->_icallout;
    void *const info = mp->_context.info;
    void (*const release)(const void *info) = mp->release;

    mp->_context.info = NULL;
    if (cb) {
        __CFUnlock(&mp->_lock);
        cb(mp, info);
        __CFLock(&mp->_lock);
    }
    if (NULL != source) {
        __CFUnlock(&mp->_lock);
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
        __CFLock(&mp->_lock);
    }
    if (release && info) {
        __CFUnlock(&mp->_lock);
        release(info);
        __CFLock(&mp->_lock);
    }
    mp->_state = kCFMachPortStateInvalid;
    OSMemoryBarrier();
}

static void __CFMachPortDeallocate(CFTypeRef cf) {
    CHECK_FOR_FORK_RET();
    CFMachPortRef mp = (CFMachPortRef)cf;

    // CFMachPortRef is invalid before we get here
    __CFLock(&mp->_lock);
    CFRunLoopSourceRef source = NULL;
    Boolean wasReady = (mp->_state == kCFMachPortStateReady);
    if (wasReady) {
        mp->_state = kCFMachPortStateInvalidating;
        OSMemoryBarrier();
        if (mp->_dsrc) {
            dispatch_source_cancel(mp->_dsrc);
            mp->_dsrc = NULL;
        }
        source = mp->_source;
        mp->_source = NULL;
    }    
    if (wasReady) {
        __CFMachPortInvalidateLocked(source, mp);
    }
    mp->_state = kCFMachPortStateDeallocating;

    const mach_port_t port = mp->_port;
    const Boolean doSend = __CFMachPortHasSend(mp), doReceive = __CFMachPortHasReceive(mp);
    __CFUnlock(&mp->_lock);
    
    _cfmp_record_deallocation(_CFMPLifetimeClientCFMachPort, port, doSend, doReceive);
    
}

// This lock protects __CFAllMachPorts. Take before any instance-specific lock.
static os_unfair_lock __CFAllMachPortsLock = OS_UNFAIR_LOCK_INIT;

static CFMutableArrayRef __CFAllMachPorts = NULL;

static Boolean __CFMachPortCheck(mach_port_t) __attribute__((noinline));
static Boolean __CFMachPortCheck(mach_port_t port) {
    mach_port_type_t type = 0;
    kern_return_t ret = mach_port_type(mach_task_self(), port, &type);
    return (KERN_SUCCESS != ret || (0 == (type & MACH_PORT_TYPE_PORT_RIGHTS))) ? false : true;
}

// This function exists regardless of platform, but is only declared in headers for legacy clients.
CF_EXPORT CFIndex CFGetRetainCount(CFTypeRef object);

static void __CFMachPortChecker(void) {
    os_unfair_lock_lock(&__CFAllMachPortsLock); // take this lock first before any instance-specific lock
    for (CFIndex idx = 0, cnt = __CFAllMachPorts ? CFArrayGetCount(__CFAllMachPorts) : 0; idx < cnt; idx++) {
        CFMachPortRef mp = (CFMachPortRef)CFArrayGetValueAtIndex(__CFAllMachPorts, idx);
        if (!mp) continue;
        // second clause cleans no-longer-wanted CFMachPorts out of our strong table
        if (!__CFMachPortCheck(mp->_port) || (1 == CFGetRetainCount(mp))) {
            CFRunLoopSourceRef source = NULL;
            Boolean wasReady = (mp->_state == kCFMachPortStateReady);
            if (wasReady) {
                __CFLock(&mp->_lock); // take this lock second
                // double check the state under lock, just in case, we should be the last reference per retain count check above... but it doesn't hurt to be robust.
                wasReady = (mp->_state == kCFMachPortStateReady);
                if (!wasReady) {
                    __CFUnlock(&mp->_lock);
                }
                else {
                    mp->_state = kCFMachPortStateInvalidating;
                    OSMemoryBarrier();
                    if (mp->_dsrc) {
                        dispatch_source_cancel(mp->_dsrc);
                        mp->_dsrc = NULL;
                    }
                    source = mp->_source;
                    mp->_source = NULL;
                    CFRetain(mp); // matched below:  <live-to-invalidate>
                    __CFUnlock(&mp->_lock);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // We can grab the mach port-specific spin lock here since we're no longer on the same thread as the one taking the all mach ports spin lock.
                        // But be sure to release it during callouts
                        __CFLock(&mp->_lock);
                        __CFMachPortInvalidateLocked(source, mp);
                        __CFUnlock(&mp->_lock);
                        CFRelease(mp); // matched above:  </live-to-invalidate>
                    });
                }
            }
            CFArrayRemoveValueAtIndex(__CFAllMachPorts, idx);
            idx--;
            cnt--;
        }
    }
    os_unfair_lock_unlock(&__CFAllMachPortsLock);
};


const CFRuntimeClass __CFMachPortClass = {
    0,
    "CFMachPort",
    NULL,      // init
    NULL,      // copy
    __CFMachPortDeallocate,
    __CFMachPortEqual,
    __CFMachPortHash,
    NULL,      // 
    __CFMachPortCopyDescription
};

CFTypeID CFMachPortGetTypeID(void) {
    return _kCFRuntimeIDCFMachPort;
}

/* Note: any receive or send rights that the port contains coming in will
 * not be cleaned up by CFMachPort; it will increment and decrement
 * references on the port if the kernel ever allows that in the future,
 * but will not cleanup any references you got when you got the port. */
CFMachPortRef _CFMachPortCreateWithPort2(CFAllocatorRef allocator, mach_port_t port, CFMachPortCallBack callout, CFMachPortContext *context, Boolean *shouldFreeInfo) {
    if (shouldFreeInfo) *shouldFreeInfo = true;
    CHECK_FOR_FORK_RET(NULL);

    mach_port_type_t type = 0;
    kern_return_t ret = mach_port_type(mach_task_self(), port, &type);
    if (KERN_SUCCESS != ret || (0 == (type & MACH_PORT_TYPE_PORT_RIGHTS))) {
        if (type & ~MACH_PORT_TYPE_DEAD_NAME) {
            CFLog(kCFLogLevelError, CFSTR("*** CFMachPortCreateWithPort(): bad Mach port parameter (0x%lx) or unsupported mysterious kind of Mach port (%d, %ld)"), (unsigned long)port, ret, (unsigned long)type);
        }
        return NULL;
    }

    CFMachPortRef mp = NULL;
    os_unfair_lock_lock(&__CFAllMachPortsLock);
    // First, do a scan for an existing CFMachPortRef for the specified port:
    if (__CFAllMachPorts != NULL) {
        CFIndex const nPorts = CFArrayGetCount(__CFAllMachPorts);
        for (CFIndex idx = 0; idx < nPorts; idx++) {
            CFMachPortRef const p = (CFMachPortRef)CFArrayGetValueAtIndex(__CFAllMachPorts, idx);
            if (p && p->_port == port) {
                CFRetain(p);
                mp = p; // mp now has +2 retain count:  1: from set  2: from this local retain
                break;
            }
        }
    }
    
    if (mp) {
        // We found a matching port, so we're done with the global lock
        os_unfair_lock_unlock(&__CFAllMachPortsLock);
    } else {
        // We need to create a new CFMachPortRef. 
        // keep the global lock a bit longer, until we add it to the set of all ports.
        CFIndex const size = sizeof(struct __CFMachPort) - sizeof(CFRuntimeBase);
        CFMachPortRef const memory = (CFMachPortRef)_CFRuntimeCreateInstance(allocator, CFMachPortGetTypeID(), size, NULL);
        if (NULL == memory) {
            os_unfair_lock_unlock(&__CFAllMachPortsLock);
            return NULL;
        }
        memory->_port = port;
        memory->_callout = callout;
        memory->_lock = CFLockInit;
        if (NULL != context) {
            memmove(&memory->_context, context, sizeof(CFMachPortContext));
            memory->_context.info = context->retain ? (void *)context->retain(context->info) : context->info;
            memory->retain = context->retain;
            memory->release = context->release;
	    memory->_context.retain = (void *)0xAAAAAAAAAACCCAAA;
            memory->_context.release = (void *)0xAAAAAAAAAABBBAAA;
        }
        memory->_state = kCFMachPortStateReady;
        if (!__CFAllMachPorts) {
            // Create the set of all mach ports if it doesn't exist
            __CFAllMachPorts = CFArrayCreateMutable(kCFAllocatorSystemDefault, 0, &kCFTypeArrayCallBacks);
        }
        CFArrayAppendValue(__CFAllMachPorts, memory);
        os_unfair_lock_unlock(&__CFAllMachPortsLock);
        mp = memory;  // NOTE: at this point mp has +2 retain count, 1: from birth  2: from being added to the set
        if (shouldFreeInfo) { *shouldFreeInfo = false; }

        if (type & MACH_PORT_TYPE_SEND_RIGHTS) {
            _cfmp_record_intent_to_invalidate(_CFMPLifetimeClientCFMachPort, port);
            dispatch_source_t theSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_SEND, port, DISPATCH_MACH_SEND_DEAD, _CFMachPortQueue());
	    if (theSource) {
                dispatch_source_set_cancel_handler(theSource, ^{
                    _cfmp_source_invalidated(_CFMPLifetimeClientCFMachPort, port);
                    dispatch_release(theSource);
                });
                dispatch_source_set_event_handler(theSource, ^{ __CFMachPortChecker(); });
                memory->_dsrc = theSource;
                dispatch_resume(theSource);
	    }
        }
    }
    
    if (mp && !CFMachPortIsValid(mp)) { // must do this outside lock to avoid deadlock
        CFRelease(mp); // NOTE: we release the extra +1 introduced in this function (or birth) so that the only potential refcount left for this frame is from the set of all ports.
        mp = NULL;
    }
    return mp;
}

CFMachPortRef CFMachPortCreateWithPort(CFAllocatorRef allocator, mach_port_t port, CFMachPortCallBack callout, CFMachPortContext *context, Boolean *shouldFreeInfo) {
    return _CFMachPortCreateWithPort2(allocator, port, callout, context, shouldFreeInfo);
}

CFMachPortRef CFMachPortCreate(CFAllocatorRef allocator, CFMachPortCallBack callout, CFMachPortContext *context, Boolean *shouldFreeInfo) {
    if (shouldFreeInfo) *shouldFreeInfo = true;
    CHECK_FOR_FORK_RET(NULL);
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t ret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (KERN_SUCCESS == ret) {
        ret = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    }
    if (KERN_SUCCESS != ret) {
        if (MACH_PORT_NULL != port) {
            // inserting the send right failed, so only decrement the receive
            mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        }
        return NULL;
    }
    CFMachPortRef result = _CFMachPortCreateWithPort2(allocator, port, callout, context, shouldFreeInfo);
    if (NULL == result) {
        if (MACH_PORT_NULL != port) {
            // both receive and send succeeded above so decrement both
            mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
            mach_port_deallocate(mach_task_self(), port);
        }
        return NULL;
    }
    __CFMachPortSetHasReceive(result);
    __CFMachPortSetHasSend(result);
    return result;
}

void CFMachPortInvalidate(CFMachPortRef mp) {
    CHECK_FOR_FORK_RET();
    CF_OBJC_FUNCDISPATCHV(CFMachPortGetTypeID(), void, (NSMachPort *)mp, invalidate);
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    CFRetain(mp); // matched below:  <live-to-invalidate>
    CFRunLoopSourceRef source = NULL;
    Boolean wasReady = false;
    os_unfair_lock_lock(&__CFAllMachPortsLock); // take this lock first
    __CFLock(&mp->_lock);
    wasReady = (mp->_state == kCFMachPortStateReady);
    if (wasReady) {
        mp->_state = kCFMachPortStateInvalidating;
        OSMemoryBarrier();
        for (CFIndex idx = 0, cnt = __CFAllMachPorts ? CFArrayGetCount(__CFAllMachPorts) : 0; idx < cnt; idx++) {
            CFMachPortRef p = (CFMachPortRef)CFArrayGetValueAtIndex(__CFAllMachPorts, idx);
            if (p == mp) {
                CFArrayRemoveValueAtIndex(__CFAllMachPorts, idx);
                break;
            }
        }
        if (mp->_dsrc) {
            dispatch_source_cancel(mp->_dsrc);
            mp->_dsrc = NULL;
        }
        source = mp->_source;
        mp->_source = NULL;
    }
    __CFUnlock(&mp->_lock);
    os_unfair_lock_unlock(&__CFAllMachPortsLock); // release this lock last
    if (wasReady) {
        __CFLock(&mp->_lock);
        __CFMachPortInvalidateLocked(source, mp);
        __CFUnlock(&mp->_lock);
    }
    CFRelease(mp); // matched above:  </live-to-invalidate>
}

mach_port_t CFMachPortGetPort(CFMachPortRef mp) {
    CHECK_FOR_FORK_RET(0);
    CF_OBJC_FUNCDISPATCHV(CFMachPortGetTypeID(), mach_port_t, (NSMachPort *)mp, machPort);
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    return mp->_port;
}

void CFMachPortGetContext(CFMachPortRef mp, CFMachPortContext *context) {
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    CFAssert1(0 == context->version, __kCFLogAssertion, "%s(): context version not initialized to 0", __PRETTY_FUNCTION__);
    memmove(context, &mp->_context, sizeof(CFMachPortContext));
}

Boolean CFMachPortIsValid(CFMachPortRef mp) {
    CF_OBJC_FUNCDISPATCHV(CFMachPortGetTypeID(), Boolean, (NSMachPort *)mp, isValid);
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    if (!__CFMachPortIsValid(mp)) return false;
    mach_port_type_t type = 0;
    MACH_PORT_TYPE_PORT_RIGHTS;
    kern_return_t ret = mach_port_type(mach_task_self(), mp->_port, &type);
    if (KERN_SUCCESS != ret || (0 == (type & MACH_PORT_TYPE_PORT_RIGHTS))) {
	return false;
    }
    return true;
}

CFMachPortInvalidationCallBack CFMachPortGetInvalidationCallBack(CFMachPortRef mp) {
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    __CFLock(&mp->_lock);
    CFMachPortInvalidationCallBack cb = mp->_icallout;
    __CFUnlock(&mp->_lock);
    return cb;
}

/* After the CFMachPort has started going invalid, or done invalid, you can't change this, and
   we'll only do the callout directly on a transition from NULL to non-NULL. */
void CFMachPortSetInvalidationCallBack(CFMachPortRef mp, CFMachPortInvalidationCallBack callout) {
    CHECK_FOR_FORK_RET();
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    if (callout) {
	mach_port_type_t type = 0;
	kern_return_t ret = mach_port_type(mach_task_self(), mp->_port, &type);
	if (KERN_SUCCESS != ret || 0 == (type & MACH_PORT_TYPE_SEND_RIGHTS)) {
	    CFLog(kCFLogLevelError, CFSTR("*** WARNING: CFMachPortSetInvalidationCallBack() called on a CFMachPort with a Mach port (0x%x) which does not have any send rights.  This is not going to work.  Callback function: %p"), mp->_port, callout);
	}
    }
    __CFLock(&mp->_lock);
    void *const info = mp->_context.info;
    if (__CFMachPortIsValid(mp) || !callout) {
        mp->_icallout = callout;
    } else if (!mp->_icallout && callout) {
        __CFUnlock(&mp->_lock);
        callout(mp, info);
        __CFLock(&mp->_lock);
    } else {
        CFLog(kCFLogLevelWarning, CFSTR("CFMachPortSetInvalidationCallBack(): attempt to set invalidation callback (%p) on invalid CFMachPort (%p) thwarted"), callout, mp);
    }
    __CFUnlock(&mp->_lock);
}

/* Returns the number of messages queued for a receive port. */
CFIndex CFMachPortGetQueuedMessageCount(CFMachPortRef mp) {  
    CHECK_FOR_FORK_RET(0);
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    mach_port_status_t status;
    mach_msg_type_number_t num = MACH_PORT_RECEIVE_STATUS_COUNT;
    kern_return_t ret = mach_port_get_attributes(mach_task_self(), mp->_port, MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&status, &num);
    return (KERN_SUCCESS != ret) ? 0 : status.mps_msgcount;
}

static mach_port_t __CFMachPortGetPort(void *info) {
    CFMachPortRef mp = (CFMachPortRef)info;
    return mp->_port;
}

CF_PRIVATE void *__CFMachPortPerform(void *msg, CFIndex size, CFAllocatorRef allocator, void *info) {
    CHECK_FOR_FORK_RET(NULL);
    CFMachPortRef mp = (CFMachPortRef)info;
    __CFLock(&mp->_lock);
    Boolean isValid = __CFMachPortIsValid(mp);
    void *context_info = NULL;
    void (*context_release)(const void *) = NULL;
    if (isValid) {
        if (mp->retain) {
            context_info = (void *)mp->retain(mp->_context.info);
            context_release = mp->release;
        } else {
            context_info = mp->_context.info;
        }
    }
    __CFUnlock(&mp->_lock);
    if (isValid) {
        mp->_callout(mp, msg, size, context_info);

        if (context_release) {
            context_release(context_info);
        }
        if (HAS_FORKED()) {
            return NULL;
        }
    }
    return NULL;
}


    
    
CFRunLoopSourceRef CFMachPortCreateRunLoopSource(CFAllocatorRef allocator, CFMachPortRef mp, CFIndex order) {
    CHECK_FOR_FORK_RET(NULL);
    __CFGenericValidateType(mp, CFMachPortGetTypeID());
    if (!CFMachPortIsValid(mp)) return NULL;
    CFRunLoopSourceRef result = NULL;
    __CFLock(&mp->_lock);
    if (__CFMachPortIsValid(mp)) {
        if (NULL != mp->_source && !CFRunLoopSourceIsValid(mp->_source)) {
            CFRelease(mp->_source);
            mp->_source = NULL;
        }
        if (NULL == mp->_source) {
            CFRunLoopSourceContext1 context;
            context.version = 1;
            context.info = (void *)mp;
            context.retain = (const void *(*)(const void *))CFRetain;
            context.release = (void (*)(const void *))CFRelease;
            context.copyDescription = (CFStringRef (*)(const void *))__CFMachPortCopyDescription;
            context.equal = (Boolean (*)(const void *, const void *))__CFMachPortEqual;
            context.hash = (CFHashCode (*)(const void *))__CFMachPortHash;
            context.getPort = __CFMachPortGetPort;
            context.perform = __CFMachPortPerform;
            mp->_source = CFRunLoopSourceCreate(allocator, order, (CFRunLoopSourceContext *)&context);
        }
        result = mp->_source ? (CFRunLoopSourceRef)CFRetain(mp->_source) : NULL;
    }
    __CFUnlock(&mp->_lock);
    return result;
}

void __CFMachMessageCheckForAndDestroyUnsentMessage(kern_return_t const kr, mach_msg_header_t *const msg) {
    // Account for the psuedo-receive of the local port described in [39359253]
    switch (kr) {
        case MACH_SEND_TIMEOUT: // fallthrough
        case MACH_SEND_INTERRUPTED: {
            mach_port_t const localPort = msg->msgh_local_port;
            if (MACH_PORT_VALID(localPort)) {
                mach_msg_bits_t const mbits = MACH_MSGH_BITS_LOCAL(msg->msgh_bits);
                if (mbits == MACH_MSG_TYPE_MOVE_SEND || mbits == MACH_MSG_TYPE_MOVE_SEND_ONCE) {
                    mach_port_deallocate(mach_task_self(), localPort);
                }
                msg->msgh_bits &= ~MACH_MSGH_BITS_LOCAL_MASK;
            }
            break;
        }
        default:
            break;
    }
    
    // [53512422] It is only reasonable to destroy the msg for the following:
    switch (kr) {
        case MACH_SEND_TIMEOUT: // fallthrough
        case MACH_SEND_INVALID_DEST:
            mach_msg_destroy(msg);
        default:
            break;
    }
}
