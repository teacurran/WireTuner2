package com.villagecompute.wiretuner.api.data;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;
import java.util.regex.Pattern;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

/**
 * Host keys (data-merge.adoc, Allowlists): {@code host} or {@code host:port}, lower case, with port
 * 443 written as no port, so an allowlist entry, a credential's host and a URL compare exactly. Also
 * the one parser every outbound URL goes through: https only, a host, no user info.
 */
public final class HostNames {

    static final int HTTPS_PORT = 443;

    /** A dotted-quad IPv4 literal. */
    static final Pattern IPV4 = Pattern.compile("^(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})$");

    /** A last label that is all digits or hex-prefixed: only a dotted quad may end like that. */
    static final Pattern NUMERIC_TAIL = Pattern.compile("(^|\\.)(0x[0-9a-f]*|[0-9]+)$");

    private HostNames() {
    }

    /** The key of an entry as typed ({@code Api.Example.com:443} is {@code api.example.com}). */
    public static String normalize(String entry) {
        String lower = entry.toLowerCase(Locale.ROOT);
        return lower.endsWith(":" + HTTPS_PORT) ? lower.substring(0, lower.length() - 4) : lower;
    }

    /** The key of a parsed URL's host and port. */
    public static String key(URI url) {
        return key(url.getHost(), url.getPort());
    }

    static String key(String host, int port) {
        String lower = host.toLowerCase(Locale.ROOT);
        return port == -1 || port == HTTPS_PORT ? lower : lower + ":" + port;
    }

    /**
     * Parses an outbound URL: absolute, https, with a host that is a DNS name, a dotted-quad IPv4
     * literal or a bracketed IPv6 literal, and no user info; the numeric disguises of an address
     * ({@code 2130706433}, {@code 0x7f000001}, {@code 127.1}) are refused. Anything else is
     * {@code INVALID_ARGUMENT / VALIDATION_FAILED} on {@code field}.
     */
    public static URI parse(String url, String field) {
        URI uri;
        try {
            uri = new URI(url);
        } catch (URISyntaxException e) {
            throw invalid(field, "not a URL");
        }
        if (!"https".equalsIgnoreCase(uri.getScheme())) {
            throw invalid(field, "only https URLs are fetched");
        }
        String host = uri.getHost();
        if (host == null) {
            throw invalid(field, "the URL has no host");
        }
        if (uri.getRawUserInfo() != null) {
            throw invalid(field, "user information in a URL is not allowed; use a credential");
        }
        String lower = host.toLowerCase(Locale.ROOT);
        if (NUMERIC_TAIL.matcher(lower).find() && !dottedQuad(lower)) {
            throw invalid(field, "a numeric host must be a dotted-quad IPv4 address");
        }
        return uri;
    }

    /** A dotted quad whose four parts are each at most 255. */
    static boolean dottedQuad(String host) {
        java.util.regex.Matcher m = IPV4.matcher(host);
        if (!m.matches()) {
            return false;
        }
        for (int i = 1; i <= 4; i++) {
            if (Integer.parseInt(m.group(i)) > 255) {
                return false;
            }
        }
        return true;
    }

    /** Whether the host is an IP literal (dotted quad or bracketed IPv6), which is never looked up. */
    static boolean literal(String host) {
        return host.startsWith("[") || dottedQuad(host);
    }

    /** The host without IPv6 brackets. */
    static String bare(String host) {
        return host.startsWith("[") ? host.substring(1, host.length() - 1) : host;
    }

    /** The request target: the raw path ("/" when empty) and query. */
    static String target(URI url) {
        return (url.getRawPath().isEmpty() ? "/" : url.getRawPath()) + (url.getRawQuery() == null ? "" : "?" + url.getRawQuery());
    }

    /** The port to connect to. */
    static int port(URI url) {
        return url.getPort() == -1 ? HTTPS_PORT : url.getPort();
    }

    static RuntimeException invalid(String field, String message) {
        return StatusExceptions.validationFailed(field + ": " + message, java.util.Map.of(field, message));
    }
}
