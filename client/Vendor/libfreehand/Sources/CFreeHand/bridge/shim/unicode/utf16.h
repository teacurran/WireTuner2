/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/* WireTuner: ICU's U16_NEXT, so the package needs no ICU.  Reads the code point at s[i] into c
 * and advances i; a lone surrogate is returned as itself, as ICU does. */
#ifndef WT_UNICODE_UTF16_H
#define WT_UNICODE_UTF16_H

#include "utf8.h"

#define U16_NEXT(s, i, length, c) do { \
    (c) = (UChar32)(s)[(i)++]; \
    if (((c) & 0xfffffc00) == 0xd800 && (i) != (length)) { \
        uint16_t wt_trail = (uint16_t)(s)[(i)]; \
        if ((wt_trail & 0xfc00) == 0xdc00) { \
            ++(i); \
            (c) = (UChar32)((((uint32_t)(c) - 0xd800) << 10) + ((uint32_t)wt_trail - 0xdc00) + 0x10000); \
        } \
    } \
} while (0)

#endif
