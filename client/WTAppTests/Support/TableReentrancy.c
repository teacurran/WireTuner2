// Catches AppKit's "Application performed a reentrant operation in its NSTableView delegate"
// warning in the test host (AppKit says it will become an assert).  On macOS 26 a SwiftUI list's
// table prints it when it re-enters its own row-height cache while it updates: filled from empty
// with more than about 200 rows, or after a run of row moves (`ListRowGrowth` in the app).
//
// AppKit prints it with NSLog, through the unified log at the default level.  A constructor in
// the test bundle installs an os_log hook (libsystem_trace's `os_log_set_hook`, called on the
// logging thread for every message at the default level and above) that counts the warning
// (`wtTableReentrancyCount`, read by TableReentrancyTests) and prints a `WT-TABLE-REENTRANCY` line
// with the call stack and the table under it (`WT-TABLE-REENTRANCY-TABLE`), so a full-suite log
// names the list.  The hook chains to any hook installed before it.  WT_NO_LOG_HOOK=1 in the test
// host's environment turns it off.

#include <Block.h>
#include <execinfo.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct os_log_message_s *wt_os_log_message_t;
typedef void (^wt_os_log_hook_t)(uint8_t level, wt_os_log_message_t message);
extern wt_os_log_hook_t os_log_set_hook(uint8_t level, wt_os_log_hook_t hook);
extern char *os_log_copy_message_string(wt_os_log_message_t message);

static _Atomic long wtReentrancies = 0;
static _Atomic long wtMessages = 0;

long wtTableReentrancyCount(void) { return atomic_load(&wtReentrancies); }
// Every message the hook saw (a test checks that the hook is in place).
long wtLogMessageCount(void) { return atomic_load(&wtMessages); }

static wt_os_log_hook_t wtPreviousHook;
// Names the table the warning came from (TableReentrancyTests.swift): the call stack often starts
// at SwiftUI's run-loop flush, with no app code on it.
extern void wtDescribeLongTables(void);
// Starts recording the tables inside endUpdates (TableReentrancyTests.swift).
extern void wtTrackTables(void);

__attribute__((constructor))
static void wtInstallLogHook(void) {
    if (getenv("WT_NO_LOG_HOOK") != NULL) return;
    wtTrackTables();
    wt_os_log_hook_t previous = os_log_set_hook(0 /* OS_LOG_TYPE_DEFAULT */, ^(uint8_t level, wt_os_log_message_t message) {
        atomic_fetch_add(&wtMessages, 1);
        char *text = os_log_copy_message_string(message);
        if (text != NULL && strstr(text, "reentrant operation in its NSTableView delegate") != NULL) {
            atomic_fetch_add(&wtReentrancies, 1);
            void *frames[128];
            int count = backtrace(frames, 128);
            fprintf(stderr, "WT-TABLE-REENTRANCY (call stack follows)\n");
            fflush(stderr);
            backtrace_symbols_fd(frames, count, STDERR_FILENO);
            wtDescribeLongTables();
            fprintf(stderr, "WT-TABLE-REENTRANCY-END\n");
            fflush(stderr);
        }
        free(text);
        if (wtPreviousHook != NULL) wtPreviousHook(level, message);
    });
    if (previous != NULL) wtPreviousHook = Block_copy(previous);
}
