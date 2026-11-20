#ifndef PM_HELPER_H
#define PM_HELPER_H

#include <stdint.h>

// kIOPMAssertionTypeNoIdleSleep is deprecated since 10.7 in favour of these,
// which is also what `caffeinate -i` and `-d` assert.
enum pm_assertion_kind {
    PM_ASSERT_IDLE_SYSTEM_SLEEP = 1,
    PM_ASSERT_IDLE_DISPLAY_SLEEP = 2,
};

// Creates an assertion of `kind`.
// Returns assertion ID on success (> 0), 0 on failure or invalid argument.
// `reason` must be non-NULL.
uint32_t pm_assert(enum pm_assertion_kind kind, const char *reason);

// Releases a power management assertion.
// Returns 0 on success, -1 on failure.
int pm_release_assertion(uint32_t id);

#endif