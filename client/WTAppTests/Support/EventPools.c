// Gives the events the tests' main thread handles an autorelease pool each, as an application's
// own event loop does.
//
// XCTest runs the whole Swift Testing run inside one event of the host app, and waits for it with
// +[XCTWaiter _synchronouslyWaitForTimeInterval:], which loops
// `while ((event = [NSApp nextEventMatchingMask:...dequeue:YES])) [NSApp sendEvent:event];` with no
// pool of its own.  What those two calls autorelease -- the events (each holding its window) and
// the windows AppKit hands around while dispatching them -- then went to the pool of the event
// that started the run, which is only popped when the last test ends: every window that lived long
// enough to get an event from the window server (a few hundred milliseconds) was never
// deallocated, with its views, canvas and document, and over a full suite the test host grew past
// 9 GB.  With a pool around each call, only NSApp's current event and the last few events handed
// out outlive it.
//
// The test bundle only (a constructor run when XCTest loads it); the app's own event loop drains
// its pools.  WT_NO_EVENT_POOLS=1 in the test host's environment turns it off.

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdlib.h>

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *token);
extern id objc_retain(id object);
extern void objc_release(id object);

typedef id (*WTNextEventIMP)(id, SEL, unsigned long long, id, id, bool);
typedef void (*WTSendEventIMP)(id, SEL, id);

static WTNextEventIMP wtOriginalNextEvent;
static WTSendEventIMP wtOriginalSendEvent;
// The events handed out by the last calls, kept alive for a few calls more: the caller gets each
// at +0 without an autorelease (which would put it back in the pool that is never popped), and a
// caller that dispatches an event while a nested loop asks for more (a modal or tracking loop in
// sendEvent:) still has its own.  Calls that return no event count too, so an idle wait lets go
// of the last events quickly.
enum { WTKeptEvents = 16 };
static id wtKeptEvents[WTKeptEvents];
static unsigned wtNextKept = 0;

static id wtNextEvent(id self, SEL command, unsigned long long mask, id date, id mode, bool dequeue) {
    void *pool = objc_autoreleasePoolPush();
    id event = objc_retain(wtOriginalNextEvent(self, command, mask, date, mode, dequeue));
    objc_autoreleasePoolPop(pool);
    id previous = wtKeptEvents[wtNextKept];
    wtKeptEvents[wtNextKept] = event;
    wtNextKept = (wtNextKept + 1) % WTKeptEvents;
    if (previous != NULL) objc_release(previous);
    return event;
}

static void wtSendEvent(id self, SEL command, id event) {
    void *pool = objc_autoreleasePoolPush();
    wtOriginalSendEvent(self, command, event);
    objc_autoreleasePoolPop(pool);
}

__attribute__((constructor))
static void wtInstallEventPools(void) {
    if (getenv("WT_NO_EVENT_POOLS") != NULL) return;
    Class application = objc_getClass("NSApplication");
    if (application == NULL) return;
    Method next = class_getInstanceMethod(application, sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:"));
    Method send = class_getInstanceMethod(application, sel_registerName("sendEvent:"));
    if (next == NULL || send == NULL) return;
    wtOriginalNextEvent = (WTNextEventIMP)method_setImplementation(next, (IMP)wtNextEvent);
    wtOriginalSendEvent = (WTSendEventIMP)method_setImplementation(send, (IMP)wtSendEvent);
}
