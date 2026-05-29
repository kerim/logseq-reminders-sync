#import "include/ReminderKitBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// =============================================================================
// PRIVATE API INVENTORY — READ THIS BEFORE TOUCHING ANYTHING BELOW
//
// The Reminders.app URL field is backed by a REMURLAttachment on the underlying
// REMReminder in the PRIVATE ReminderKit framework. The public EKCalendarItem.url
// is completely disconnected from what the app displays (confirmed empirically,
// macOS 26, May 2026). This file reaches the real field via runtime introspection.
//
// Verified working on: macOS 26.x (May 2026)
// Ported from: go-eventkit v0.5.0 (MIT), reminders/bridge_darwin.m
//
// PRIVATE FRAMEWORKS (dlopen'd at runtime, NOT linked):
//   /System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit
//   /System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal
//
// PRIVATE CLASSES:
//   REMReminder    — the backing reminder object under an EKReminder
//   REMStore       — the private reminder store
//   REMSaveRequest — a transactional save request
//
// PRIVATE IVARS (walked via class_getInstanceVariable + superclass chain):
//   _remObject  — ivar on EKReminder's backingObject; holds the REMReminder
//   _store      — ivar on REMReminder; holds the REMStore
//
// PRIVATE SELECTORS (looked up via NSSelectorFromString at runtime):
//   backingObject              — on EKReminder; returns the EK backing object
//   store                      — on REMReminder; fallback if _store ivar absent
//   initWithStore:             — on REMSaveRequest
//   updateReminder:            — on REMSaveRequest; returns a change item
//   attachmentContext          — on REMReminder and on the change item
//   urlAttachments             — on the attachment context; returns NSArray
//   url                        — on a REMURLAttachment item
//   setURLAttachmentWithURL:   — on the attachment context; sets the URL
//   removeURLAttachments       — on the attachment context; clears the URL
//   saveSynchronouslyWithError: — on REMSaveRequest; commits the change
//
// IF LRSWriteReminderURLAttachment STARTS RETURNING NO:
//   A macOS update probably renamed or removed one of the symbols above.
//   Steps to diagnose:
//   1. class-dump or Hopper the new ReminderKit.framework to find the current names.
//   2. Update the NSSelectorFromString / objc_getClass / find_ivar call sites below.
//   3. Re-run build 19 (or later) and confirm the link appears in the Reminders app.
//   There is intentionally no fallback — the backlink just won't appear until fixed.
// =============================================================================

// Load both private frameworks once. Returns YES if both loaded.
static BOOL load_reminderkit(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h1 = dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
                          RTLD_NOW | RTLD_LAZY);
        void *h2 = dlopen("/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal",
                          RTLD_NOW | RTLD_LAZY);
        loaded = (h1 != NULL && h2 != NULL);
    });
    return loaded;
}

// Walk the ivar list of cls and its superclasses to find an ivar by name.
static Ivar find_ivar(Class cls, const char *name) {
    while (cls) {
        Ivar v = class_getInstanceVariable(cls, name);
        if (v) return v;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

// Extract REMReminder from an EKReminder via backingObject._remObject.
// Returns nil if the private class layout has changed.
static id rem_reminder_from_ek(EKReminder *r) {
    if (!r) return nil;
    SEL boSel = NSSelectorFromString(@"backingObject");
    if (![r respondsToSelector:boSel]) return nil;
    id bo = ((id (*)(id, SEL))objc_msgSend)(r, boSel);
    if (!bo) return nil;
    Ivar ri = find_ivar([bo class], "_remObject");
    if (!ri) return nil;
    id remObj = object_getIvar(bo, ri);
    Class remReminderClass = objc_getClass("REMReminder");
    if (!remReminderClass || ![remObj isKindOfClass:remReminderClass]) return nil;
    return remObj;
}

NSString *_Nullable LRSReadReminderURLAttachment(EKReminder *reminder) {
    if (!load_reminderkit()) return nil;
    id remReminder = rem_reminder_from_ek(reminder);
    if (!remReminder) return nil;
    SEL ctxSel = NSSelectorFromString(@"attachmentContext");
    if (![remReminder respondsToSelector:ctxSel]) return nil;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(remReminder, ctxSel);
    if (!ctx) return nil;
    SEL urlAttsSel = NSSelectorFromString(@"urlAttachments");
    if (![ctx respondsToSelector:urlAttsSel]) return nil;
    id atts = ((id (*)(id, SEL))objc_msgSend)(ctx, urlAttsSel);
    if (!atts || ![atts respondsToSelector:@selector(count)] || [atts count] == 0) return nil;
    id first = [atts firstObject];
    SEL urlSel = NSSelectorFromString(@"url");
    if (![first respondsToSelector:urlSel]) return nil;
    id u = ((id (*)(id, SEL))objc_msgSend)(first, urlSel);
    if ([u isKindOfClass:[NSURL class]]) return [(NSURL *)u absoluteString];
    if ([u isKindOfClass:[NSString class]]) return (NSString *)u;
    return nil;
}

// Write (or clear) the REMURLAttachment.
// Returns YES iff saveSynchronouslyWithError: succeeded.
// Returns NO on any guard miss (symbol changed) OR a save rejection.
// Caller logs the NO — see the inventory comment at the top.
BOOL LRSWriteReminderURLAttachment(EKReminder *reminder, NSString *_Nullable url) {
    if (!load_reminderkit()) return NO;
    id remReminder = rem_reminder_from_ek(reminder);
    if (!remReminder) return NO;

    // Get REMStore via _store ivar, falling back to -store selector.
    id remStore = nil;
    Ivar storeIvar = find_ivar([remReminder class], "_store");
    if (storeIvar) remStore = object_getIvar(remReminder, storeIvar);
    if (!remStore) {
        SEL storeSel = NSSelectorFromString(@"store");
        if ([remReminder respondsToSelector:storeSel]) {
            remStore = ((id (*)(id, SEL))objc_msgSend)(remReminder, storeSel);
        }
    }
    Class remStoreClass = objc_getClass("REMStore");
    if (!remStore || !remStoreClass || ![remStore isKindOfClass:remStoreClass]) return NO;

    Class saveReqClass = objc_getClass("REMSaveRequest");
    if (!saveReqClass) return NO;
    id saveReq = [saveReqClass alloc];
    SEL initSel = NSSelectorFromString(@"initWithStore:");
    if (![saveReq respondsToSelector:initSel]) return NO;
    saveReq = ((id (*)(id, SEL, id))objc_msgSend)(saveReq, initSel, remStore);
    if (!saveReq) return NO;

    SEL updateSel = NSSelectorFromString(@"updateReminder:");
    if (![saveReq respondsToSelector:updateSel]) return NO;
    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(saveReq, updateSel, remReminder);
    if (!changeItem) return NO;

    SEL ctxSel = NSSelectorFromString(@"attachmentContext");
    if (![changeItem respondsToSelector:ctxSel]) return NO;
    id attachCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, ctxSel);
    if (!attachCtx) return NO;

    if (url && url.length > 0) {
        SEL setURLAttSel = NSSelectorFromString(@"setURLAttachmentWithURL:");
        if (![attachCtx respondsToSelector:setURLAttSel]) return NO;
        NSURL *u = [NSURL URLWithString:url];
        if (!u) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(attachCtx, setURLAttSel, u);
    } else {
        SEL removeAllSel = NSSelectorFromString(@"removeURLAttachments");
        if (![attachCtx respondsToSelector:removeAllSel]) return NO;
        ((void (*)(id, SEL))objc_msgSend)(attachCtx, removeAllSel);
    }

    SEL saveSel = NSSelectorFromString(@"saveSynchronouslyWithError:");
    if (![saveReq respondsToSelector:saveSel]) return NO;
    NSError *err = nil;
    BOOL saved = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(saveReq, saveSel, &err);
    return saved;
}
