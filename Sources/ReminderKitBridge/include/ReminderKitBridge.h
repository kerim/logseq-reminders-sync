#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Write (or clear, if url is nil/empty) the REMURLAttachment that Reminders.app
 * shows in its URL field. Returns YES on success.
 *
 * Returns NO if the private ReminderKit API is unavailable or has changed.
 * The caller MUST log this loudly — it means a macOS update likely broke one of
 * the private symbols enumerated in ReminderKitBridge.m. There is intentionally
 * no fallback; the backlink simply won't appear. See the maintenance comment in
 * ReminderKitBridge.m for how to diagnose and repair.
 */
BOOL LRSWriteReminderURLAttachment(EKReminder *reminder, NSString *_Nullable url);

/**
 * Read back the first URL attachment from Reminders.app's URL field, or nil.
 * Used for the best-effort idempotency skip in setURLAttachment — not as a
 * success gate after a write.
 */
NSString *_Nullable LRSReadReminderURLAttachment(EKReminder *reminder);

NS_ASSUME_NONNULL_END
