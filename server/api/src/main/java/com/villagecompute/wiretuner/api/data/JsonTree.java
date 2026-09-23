package com.villagecompute.wiretuner.api.data;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;

/**
 * JSON values as the data service reads them (data-merge.adoc, Pagination engine and extraction):
 * objects are {@link Map}s in source order (a repeated key keeps its first position and its last
 * value), arrays {@link List}s, strings {@link String}s, booleans {@link Boolean}s, null
 * {@link #NULL}, and numbers {@link Num}, which keep their source text so a value renders exactly as
 * the upstream wrote it ({@code 1.50} stays {@code 1.50}).
 *
 * <p>{@link #compact} renders a value as compact JSON: no whitespace, members in source order,
 * numbers as their source text, and strings escaping only {@code "}, {@code \}, and the control
 * characters (as {@code \b \f \n \r \t}, or {@code \}{@code u00xx} in lower-case hex). The Swift
 * client's reader renders the same way; the shared vectors hold both to it.
 */
public final class JsonTree {

    /** JSON null (a map cannot hold Java null as a present value). */
    public static final Object NULL = new Object() {
        @Override
        public String toString() {
            return "null";
        }
    };

    /** A number with its source text. */
    public record Num(String text) {
    }

    private static final JsonFactory FACTORY = new JsonFactory();

    private JsonTree() {
    }

    /** Parses one JSON document; anything after the root value is an error. */
    public static Object parse(byte[] json) throws IOException {
        try (JsonParser parser = FACTORY.createParser(json)) {
            JsonToken token = parser.nextToken();
            if (token == null) {
                throw new IOException("empty document");
            }
            Object value = value(parser, token);
            if (parser.nextToken() != null) {
                throw new IOException("content after the JSON value");
            }
            return value;
        }
    }

    private static Object value(JsonParser parser, JsonToken token) throws IOException {
        switch (token) {
            case START_OBJECT -> {
                Map<String, Object> object = new LinkedHashMap<>();
                for (JsonToken next = parser.nextToken(); next != JsonToken.END_OBJECT; next = parser.nextToken()) {
                    String name = parser.currentName();
                    object.put(name, value(parser, parser.nextToken()));
                }
                return object;
            }
            case START_ARRAY -> {
                List<Object> array = new ArrayList<>();
                for (JsonToken next = parser.nextToken(); next != JsonToken.END_ARRAY; next = parser.nextToken()) {
                    array.add(value(parser, next));
                }
                return array;
            }
            case VALUE_STRING -> {
                return parser.getText();
            }
            case VALUE_NUMBER_INT, VALUE_NUMBER_FLOAT -> {
                return new Num(parser.getText());
            }
            case VALUE_TRUE -> {
                return Boolean.TRUE;
            }
            case VALUE_FALSE -> {
                return Boolean.FALSE;
            }
            default -> {
                return NULL;
            }
        }
    }

    /** Compact JSON for a value. */
    public static String compact(Object value) {
        StringBuilder out = new StringBuilder();
        write(out, value);
        return out.toString();
    }

    /**
     * A value as a record field's text: a string's contents, a number's source text, {@code true} or
     * {@code false}, compact JSON for objects and arrays; null for JSON null.
     */
    public static String text(Object value) {
        if (value == NULL) {
            return null;
        }
        if (value instanceof String string) {
            return string;
        }
        return compact(value);
    }

    @SuppressWarnings("unchecked")
    private static void write(StringBuilder out, Object value) {
        if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<String, Object> member : ((Map<String, Object>) map).entrySet()) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                string(out, member.getKey());
                out.append(':');
                write(out, member.getValue());
            }
            out.append('}');
        } else if (value instanceof List<?> list) {
            out.append('[');
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) {
                    out.append(',');
                }
                write(out, list.get(i));
            }
            out.append(']');
        } else if (value instanceof String string) {
            string(out, string);
        } else if (value instanceof Num number) {
            out.append(number.text());
        } else {
            out.append(value);
        }
    }

    private static void string(StringBuilder out, String value) {
        out.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }
}
