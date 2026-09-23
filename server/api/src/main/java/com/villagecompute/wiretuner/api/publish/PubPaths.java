package com.villagecompute.wiretuner.api.publish;

import java.io.ByteArrayOutputStream;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * The request paths of the pub origin (publish-html.adoc, Server): {@code /d/<document id>/<path>},
 * where the path is a bundle path, percent-encoded, and empty for {@code index.html}. Parsed on the
 * raw path, never a normalised one, so {@code ..} and encoded tricks ({@code %2e%2e}, {@code %2f},
 * backslashes, control characters, invalid UTF-8) are refused rather than resolved.
 */
final class PubPaths {

    /** A parsed request: a bundle path, a redirect to add the trailing slash, or a refusal. */
    record Parsed(int status, UUID document, String path) {
    }

    static final int OK = 200;
    static final int MOVED = 301;
    static final int BAD_REQUEST = 400;
    static final int NOT_FOUND = 404;

    static final String PREFIX = "/d/";
    static final String INDEX = "index.html";

    private static final Pattern UUID_TEXT = Pattern.compile(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");

    private PubPaths() {
    }

    static Parsed parse(String raw) {
        if (!raw.startsWith(PREFIX)) {
            return new Parsed(NOT_FOUND, null, null);
        }
        String rest = raw.substring(PREFIX.length());
        int slash = rest.indexOf('/');
        String id = slash < 0 ? rest : rest.substring(0, slash);
        if (!UUID_TEXT.matcher(id).matches()) {
            return new Parsed(NOT_FOUND, null, null);
        }
        UUID document = UUID.fromString(id);
        if (slash < 0) {
            return new Parsed(MOVED, document, null);
        }
        String encoded = rest.substring(slash + 1);
        if (encoded.isEmpty()) {
            return new Parsed(OK, document, INDEX);
        }
        List<String> segments = new ArrayList<>();
        for (String part : encoded.split("/", -1)) {
            String segment = decode(part);
            if (segment == null || segment.isEmpty() || segment.equals(".") || segment.equals("..")
                    || !segment.chars().allMatch(c -> c >= 0x20 && c != 0x7f && c != '/' && c != '\\')) {
                return new Parsed(BAD_REQUEST, document, null);
            }
            segments.add(segment);
        }
        return new Parsed(OK, document, String.join("/", segments));
    }

    /** Percent-decodes one segment as UTF-8; null when an escape or the bytes are invalid. */
    static String decode(String part) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (int i = 0; i < part.length(); i++) {
            char c = part.charAt(i);
            if (c != '%') {
                bytes.writeBytes(String.valueOf(c).getBytes(StandardCharsets.UTF_8));
                continue;
            }
            int high = i + 2 < part.length() ? Character.digit(part.charAt(i + 1), 16) : -1;
            int low = high < 0 ? -1 : Character.digit(part.charAt(i + 2), 16);
            if (low < 0) {
                return null;
            }
            bytes.write(high * 16 + low);
            i += 2;
        }
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
        } catch (CharacterCodingException e) {
            return null;
        }
    }
}
