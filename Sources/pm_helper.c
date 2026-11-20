#include "pm_helper.h"
#include <IOKit/pwr_mgt/IOPMLib.h>

uint32_t pm_assert(enum pm_assertion_kind kind, const char *reason) {
    if (!reason) return 0;

    CFStringRef type;
    switch (kind) {
    case PM_ASSERT_IDLE_SYSTEM_SLEEP:
        type = kIOPMAssertPreventUserIdleSystemSleep;
        break;
    case PM_ASSERT_IDLE_DISPLAY_SLEEP:
        type = kIOPMAssertPreventUserIdleDisplaySleep;
        break;
    default:
        return 0;
    }

    CFStringRef reasonStr = CFStringCreateWithCString(
        kCFAllocatorDefault, reason, kCFStringEncodingUTF8);
    if (!reasonStr) return 0;

    IOPMAssertionID assertionID = 0;
    IOReturn ret = IOPMAssertionCreateWithName(
        type, kIOPMAssertionLevelOn, reasonStr, &assertionID);

    CFRelease(reasonStr);
    return ret == kIOReturnSuccess ? assertionID : 0;
}

int pm_release_assertion(uint32_t id) {
    if (id == 0) return 0;
    return IOPMAssertionRelease(id) == kIOReturnSuccess ? 0 : -1;
}