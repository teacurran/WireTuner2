package com.villagecompute.wiretuner.api.grpc;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;
import java.util.UUID;

/**
 * Opaque list cursors (docs/spec/security.adoc: "Lists page with opaque cursors"): the keyset
 * position of the last row of a page, as base64url of its parts. Clients never look inside; a
 * cursor that does not decode to the expected number of parts is {@code VALIDATION_FAILED}.
 */
public final class Cursors {

    /** The default and the maximum page sizes for the lists capped at 50 by their protos. */
    public static final int SMALL_PAGE = 50;

    private static final String SEPARATOR = "\u001f";

    private Cursors() {
    }

    public static String encode(String... parts) {
        return Base64.getUrlEncoder().withoutPadding()
                .encodeToString(String.join(SEPARATOR, parts).getBytes(StandardCharsets.UTF_8));
    }

    /** The parts of a cursor produced by {@link #encode} with {@code count} parts. */
    public static String[] decode(String cursor, int count) {
        String[] parts;
        try {
            parts = new String(Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8).split(SEPARATOR, -1);
        } catch (IllegalArgumentException e) {
            throw invalid();
        }
        if (parts.length != count) {
            throw invalid();
        }
        return parts;
    }

    /** A cursor part that must be a UUID. */
    public static UUID uuid(String part) {
        try {
            return UUID.fromString(part);
        } catch (IllegalArgumentException e) {
            throw invalid();
        }
    }

    /** A cursor part that must be a float. */
    public static float real(String part) {
        try {
            return Float.parseFloat(part);
        } catch (NumberFormatException e) {
            throw invalid();
        }
    }

    /** A cursor part that must be a non-negative int (an offset). */
    public static int offset(String part) {
        try {
            int value = Integer.parseInt(part);
            if (value < 0) {
                throw invalid();
            }
            return value;
        } catch (NumberFormatException e) {
            throw invalid();
        }
    }

    /** The page size a request asked for: 0 selects {@code defaultSize}. */
    public static int pageSize(int requested, int defaultSize) {
        return requested == 0 ? defaultSize : requested;
    }

    /** A malformed cursor, as the validation error the client branches on. */
    public static RuntimeException invalid() {
        return StatusExceptions.validationFailed("the cursor is not one this server issued",
                Map.of("cursor", "not a cursor this server issued"));
    }
}
