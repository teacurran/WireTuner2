package com.villagecompute.wiretuner.api.data;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * The JSONPath subset of data merge (data-merge.adoc, Pagination engine and extraction), shared with
 * the client's JSON reader through the vectors in {@code server/api/src/test/resources/jsonpath-vectors}.
 *
 * <pre>
 * path    = ""                      the root
 *         | "$" step*
 *         | bare                    any text not starting with "$": one member of that exact name
 * step    = "." name                member
 *         | "[" quoted "]"          member, 'single' or "double" quoted; \\ \' \" escape
 *         | "[" index "]"           array element, 0-based, no sign
 *         | "[*]"                   every array element, or every member value of an object
 *         | ".." name               that member of the node and of every node below it, in document order
 * name    = one or more of A-Z a-z 0-9 _ - $ or any non-ASCII character
 * </pre>
 *
 * Anything else is refused with a {@link Kind}: filters ({@code [?(...)]}), script expressions
 * ({@code [(...)]}), slices ({@code [0:2]}), unions ({@code [0,1]}), negative indexes, and plain
 * syntax errors. A path is <em>definite</em> when it has no {@code [*]} and no {@code ..}: it matches
 * at most one value.
 */
public final class JsonPath {

    /** Why a path was refused; the vectors name these in lower case. */
    public enum Kind {
        SYNTAX, FILTER, SCRIPT, SLICE, UNION, NEGATIVE_INDEX
    }

    /** A refused path. */
    public static final class PathException extends IllegalArgumentException {
        private static final long serialVersionUID = 1L;

        private final Kind kind;

        PathException(Kind kind, String message) {
            super(message);
            this.kind = kind;
        }

        public Kind kind() {
            return kind;
        }
    }

    private enum StepType {
        MEMBER, INDEX, WILDCARD, DESCENDANT
    }

    private record Step(StepType type, String name, int index) {
    }

    private final String source;
    private final List<Step> steps;
    private final boolean definite;

    private JsonPath(String source, List<Step> steps) {
        this.source = source;
        this.steps = steps;
        this.definite = steps.stream().noneMatch(s -> s.type == StepType.WILDCARD || s.type == StepType.DESCENDANT);
    }

    public String source() {
        return source;
    }

    public boolean definite() {
        return definite;
    }

    /** Parses a path; refused paths throw {@link PathException}. */
    public static JsonPath parse(String path) {
        if (path.isEmpty()) {
            return new JsonPath(path, List.of());
        }
        if (path.charAt(0) != '$') {
            return new JsonPath(path, List.of(new Step(StepType.MEMBER, path, 0)));
        }
        return new JsonPath(path, new Parser(path).steps());
    }

    /** Every value the path matches, in document order. */
    public List<Object> evaluate(Object root) {
        List<Object> current = List.of(root);
        for (Step step : steps) {
            List<Object> next = new ArrayList<>();
            for (Object node : current) {
                apply(step, node, next);
            }
            current = next;
        }
        return current;
    }

    private static void apply(Step step, Object node, List<Object> out) {
        switch (step.type) {
            case MEMBER -> {
                if (node instanceof Map<?, ?> map && map.containsKey(step.name)) {
                    out.add(map.get(step.name));
                }
            }
            case INDEX -> {
                if (node instanceof List<?> list && step.index < list.size()) {
                    out.add(list.get(step.index));
                }
            }
            case WILDCARD -> {
                if (node instanceof List<?> list) {
                    out.addAll(list);
                } else if (node instanceof Map<?, ?> map) {
                    out.addAll(map.values());
                }
            }
            default -> descend(step.name, node, out);
        }
    }

    private static void descend(String name, Object node, List<Object> out) {
        if (node instanceof Map<?, ?> map) {
            if (map.containsKey(name)) {
                out.add(map.get(name));
            }
            for (Object child : map.values()) {
                descend(name, child, out);
            }
        } else if (node instanceof List<?> list) {
            for (Object child : list) {
                descend(name, child, out);
            }
        }
    }

    /**
     * The records a {@code records_path} selects: every match, except that a definite path matching
     * one array selects its elements ({@code $.data} reads like {@code $.data[*]}; the empty path reads
     * the root array's elements, or a root object as one record).
     */
    public List<Object> records(Object root) {
        List<Object> matches = evaluate(root);
        if (definite && matches.size() == 1 && matches.get(0) instanceof List<?> list) {
            return new ArrayList<>(list);
        }
        return matches;
    }

    /**
     * A record field's text: a definite path's match as {@link JsonTree#text}; an indefinite path's
     * matches as a compact JSON array. Null when nothing (or JSON null, for a definite path) matched.
     */
    public String extract(Object record) {
        List<Object> matches = evaluate(record);
        if (matches.isEmpty()) {
            return null;
        }
        return definite ? JsonTree.text(matches.get(0)) : JsonTree.compact(matches);
    }

    /** A recursive-descent parser over one path string. */
    private static final class Parser {
        private final String path;
        private int at = 1;

        Parser(String path) {
            this.path = path;
        }

        List<Step> steps() {
            List<Step> steps = new ArrayList<>();
            while (at < path.length()) {
                char c = path.charAt(at);
                if (c == '.') {
                    if (at + 1 < path.length() && path.charAt(at + 1) == '.') {
                        at += 2;
                        steps.add(new Step(StepType.DESCENDANT, name(), 0));
                    } else {
                        at++;
                        steps.add(new Step(StepType.MEMBER, name(), 0));
                    }
                } else if (c == '[') {
                    at++;
                    steps.add(bracket());
                } else {
                    throw error(Kind.SYNTAX, "expected '.' or '['");
                }
            }
            return steps;
        }

        private String name() {
            int start = at;
            while (at < path.length() && nameChar(path.charAt(at))) {
                at++;
            }
            if (at == start) {
                throw error(Kind.SYNTAX, "expected a member name");
            }
            return path.substring(start, at);
        }

        static boolean nameChar(char c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
                    || c == '$' || c > 127;
        }

        private Step bracket() {
            if (at >= path.length()) {
                throw error(Kind.SYNTAX, "unterminated '['");
            }
            char c = path.charAt(at);
            Step step;
            if (c == '?') {
                throw error(Kind.FILTER, "filter expressions are not supported");
            } else if (c == '(') {
                throw error(Kind.SCRIPT, "script expressions are not supported");
            } else if (c == '*') {
                at++;
                step = new Step(StepType.WILDCARD, null, 0);
            } else if (c == '\'' || c == '"') {
                step = new Step(StepType.MEMBER, quoted(c), 0);
            } else if (c == '-') {
                throw error(Kind.NEGATIVE_INDEX, "negative indexes are not supported");
            } else {
                step = new Step(StepType.INDEX, null, index());
            }
            close();
            return step;
        }

        private String quoted(char quote) {
            StringBuilder name = new StringBuilder();
            at++;
            while (at < path.length()) {
                char c = path.charAt(at++);
                if (c == quote) {
                    return name.toString();
                }
                if (c == '\\' && at < path.length()) {
                    char escaped = path.charAt(at++);
                    if (escaped != '\\' && escaped != '\'' && escaped != '"') {
                        throw error(Kind.SYNTAX, "unknown escape \\" + escaped);
                    }
                    c = escaped;
                }
                name.append(c);
            }
            throw error(Kind.SYNTAX, "unterminated quoted name");
        }

        private int index() {
            int start = at;
            while (at < path.length() && path.charAt(at) >= '0' && path.charAt(at) <= '9') {
                at++;
            }
            String digits = path.substring(start, at);
            if (digits.isEmpty() || (digits.length() > 1 && digits.charAt(0) == '0') || digits.length() > 9) {
                throw after(Kind.SYNTAX, "expected an index, '*' or a quoted name");
            }
            return Integer.parseInt(digits);
        }

        private void close() {
            if (at < path.length() && path.charAt(at) == ']') {
                at++;
                return;
            }
            throw after(Kind.SYNTAX, "expected ']'");
        }

        /** An error at the current position, classifying slices and unions by what follows. */
        private PathException after(Kind fallback, String message) {
            if (at < path.length() && path.charAt(at) == ':') {
                return error(Kind.SLICE, "slices are not supported");
            }
            if (at < path.length() && path.charAt(at) == ',') {
                return error(Kind.UNION, "unions are not supported");
            }
            return error(fallback, message);
        }

        private PathException error(Kind kind, String message) {
            return new PathException(kind, message + " at offset " + at + " of " + path);
        }
    }

    @Override
    public String toString() {
        return source;
    }
}
