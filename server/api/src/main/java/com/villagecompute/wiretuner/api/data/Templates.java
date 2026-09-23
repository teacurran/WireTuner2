package com.villagecompute.wiretuner.api.data;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.function.UnaryOperator;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.villagecompute.wiretuner.doc.v1.HttpParam;
import com.villagecompute.wiretuner.doc.v1.HttpSource;

/**
 * {@code {{param}}} expansion and the page parameter (data-merge.adoc, Pagination engine and
 * extraction). A reference is {@code {{name}}}, spaces allowed inside the braces; its value is the
 * one typed for the fetch, else the source's default, else empty. In a URL the value is
 * percent-encoded (every byte but the unreserved {@code A-Z a-z 0-9 - . _ ~}), so a value can never
 * add a path segment, a query parameter or a host; in the body it is inserted as typed.
 */
public final class Templates {

    static final Pattern REFERENCE = Pattern.compile("\\{\\{\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\}\\}");

    private Templates() {
    }

    /** The values in effect: the source's defaults overridden by the typed ones. */
    public static Map<String, String> values(HttpSource source, Map<String, String> typed) {
        Map<String, String> values = new HashMap<>();
        for (HttpParam param : source.getParamsList()) {
            values.put(param.getName(), param.getDefaultValue());
        }
        values.putAll(typed);
        return values;
    }

    /** The URL with every reference replaced by its percent-encoded value. */
    public static String url(String template, Map<String, String> values) {
        return expand(template, values, Templates::encode);
    }

    /** The body with every reference replaced by its value as typed. */
    public static String body(String template, Map<String, String> values) {
        return expand(template, values, UnaryOperator.identity());
    }

    private static String expand(String template, Map<String, String> values, UnaryOperator<String> escape) {
        Matcher matcher = REFERENCE.matcher(template);
        StringBuilder out = new StringBuilder();
        while (matcher.find()) {
            matcher.appendReplacement(out, Matcher.quoteReplacement(escape.apply(values.getOrDefault(matcher.group(1), ""))));
        }
        matcher.appendTail(out);
        return out.toString();
    }

    /** RFC 3986 percent-encoding of everything but the unreserved characters. */
    static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20").replace("*", "%2A").replace("%7E", "~");
    }

    /** The URL with the query parameter {@code name} set to {@code value}, replacing any occurrence of it. */
    public static URI withQueryParameter(URI url, String name, String value) {
        String encodedName = encode(name);
        StringBuilder query = new StringBuilder();
        String raw = url.getRawQuery();
        if (raw != null) {
            for (String pair : raw.split("&", -1)) {
                String key = pair.contains("=") ? pair.substring(0, pair.indexOf('=')) : pair;
                if (!key.equals(encodedName) && !pair.isEmpty()) {
                    query.append(pair).append('&');
                }
            }
        }
        query.append(encodedName).append('=').append(encode(value));
        String path = url.getRawPath().isEmpty() ? "/" : url.getRawPath();
        return URI.create(url.getScheme() + "://" + url.getRawAuthority() + path + "?" + query);
    }
}
