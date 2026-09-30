/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/* WireTuner: the two ICU UTF-8 macros libfreehand uses, so the package needs no ICU.  Same
 * contract as ICU's: U8_APPEND_UNSAFE writes the code point `c` at s[i] and advances i. */
#ifndef WT_UNICODE_UTF8_H
#define WT_UNICODE_UTF8_H

#include <stdint.h>

typedef int32_t UChar32;

#define U8_MAX_LENGTH 4

#define U8_APPEND_UNSAFE(s, i, c) do { \
    uint32_t wt_c = (uint32_t)(c); \
    if (wt_c <= 0x7f) { \
        (s)[(i)++] = (uint8_t)wt_c; \
    } else if (wt_c <= 0x7ff) { \
        (s)[(i)++] = (uint8_t)((wt_c >> 6) | 0xc0); \
        (s)[(i)++] = (uint8_t)((wt_c & 0x3f) | 0x80); \
    } else if (wt_c <= 0xffff) { \
        (s)[(i)++] = (uint8_t)((wt_c >> 12) | 0xe0); \
        (s)[(i)++] = (uint8_t)(((wt_c >> 6) & 0x3f) | 0x80); \
        (s)[(i)++] = (uint8_t)((wt_c & 0x3f) | 0x80); \
    } else { \
        (s)[(i)++] = (uint8_t)((wt_c >> 18) | 0xf0); \
        (s)[(i)++] = (uint8_t)(((wt_c >> 12) & 0x3f) | 0x80); \
        (s)[(i)++] = (uint8_t)(((wt_c >> 6) & 0x3f) | 0x80); \
        (s)[(i)++] = (uint8_t)((wt_c & 0x3f) | 0x80); \
    } \
} while (0)

#endif
