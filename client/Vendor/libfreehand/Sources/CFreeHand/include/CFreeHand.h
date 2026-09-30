/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/* The FreeHand importer's door into libfreehand (docs/spec/decisions.adoc D-083).  libfreehand
 * parses the file into its record collector; instead of drawing through librevenge, the bridge
 * writes every collected record out as one JSON document, which WTInterchange's FreeHandImporter
 * decodes and converts.  Plain C so Swift imports it without C++ interop. */
#ifndef CFREEHAND_H
#define CFREEHAND_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the bytes are a FreeHand document libfreehand reads (FreeHand 3 to MX / 11), else 0. */
int wt_freehand_is_supported(const unsigned char *data, size_t size);

/* The file's records as UTF-8 JSON (malloc'd, NUL-terminated; free with wt_freehand_free), with
 * its byte count in *length.  NULL when the bytes are not a FreeHand document.  A file that ends
 * early still yields the records read before the damage, with "complete": false. */
char *wt_freehand_export_records(const unsigned char *data, size_t size, size_t *length);

/* Frees a string returned by wt_freehand_export_records. */
void wt_freehand_free(char *json);

#ifdef __cplusplus
}
#endif

#endif
