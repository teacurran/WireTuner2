package com.villagecompute.wiretuner.api.data;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

/**
 * The header rules of the fetch proxy (data-merge.adoc, Fetch proxy and SSRF guard): a request
 * definition may not carry a credential -- {@code Authorization}, {@code Proxy-Authorization},
 * {@code Cookie}, {@code X-Api-Key} or the header the named credential sets -- nor a header the
 * server owns ({@code Host}, {@code Content-Length}, {@code Transfer-Encoding} and the other
 * connection headers). Either is {@code INVALID_ARGUMENT / VALIDATION_FAILED} naming the header.
 */
final class RequestHeaders {

    static final Set<String> SECRET = Set.of("authorization", "proxy-authorization", "cookie", "x-api-key");
    static final Set<String> CONNECTION = Set.of("host", "content-length", "transfer-encoding", "connection", "keep-alive",
            "upgrade", "te", "trailer", "proxy-connection", "expect");
    static final Pattern TOKEN = Pattern.compile("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

    private RequestHeaders() {
    }

    /**
     * The headers, names in lower case, checked; {@code credentialHeader} is the lower-case header the
     * credential sets (null without one). A later header of the same name replaces an earlier one.
     */
    static Map<String, String> check(Map<String, String> headers, String credentialHeader, String field) {
        Map<String, String> checked = new LinkedHashMap<>();
        headers.forEach((name, value) -> {
            String lower = name.toLowerCase(Locale.ROOT);
            if (!TOKEN.matcher(name).matches()) {
                throw refused(field, "\"" + name + "\" is not a header name");
            }
            if (SECRET.contains(lower) || lower.equals(credentialHeader)) {
                throw refused(field, "header " + name + " carries a credential; use credential_name");
            }
            if (CONNECTION.contains(lower)) {
                throw refused(field, "header " + name + " is set by the server");
            }
            checked.put(lower, value);
        });
        return checked;
    }

    private static RuntimeException refused(String field, String message) {
        return StatusExceptions.validationFailed(field + ": " + message, Map.of(field, message));
    }
}
