package com.villagecompute.wiretuner.api.data;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.stream.Stream;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;

/**
 * DATA-009: the JSONPath subset and the record rendering against the shared vectors in
 * {@code src/test/resources/jsonpath-vectors/vectors.json}, which the client's reader (DATA-004) runs
 * unchanged; plus the JSON reader's own edges.
 */
class JsonPathVectorsTest {

    static JsonObject vectors() throws IOException {
        try (InputStream in = JsonPathVectorsTest.class.getResourceAsStream("/jsonpath-vectors/vectors.json")) {
            return new JsonObject(new String(in.readAllBytes(), StandardCharsets.UTF_8));
        }
    }

    static Stream<Arguments> paths() throws IOException {
        return vectors().getJsonArray("paths").stream().map(o -> Arguments.of(((JsonObject) o).getString("name"), o));
    }

    static Stream<Arguments> records() throws IOException {
        return vectors().getJsonArray("records").stream().map(o -> Arguments.of(((JsonObject) o).getString("name"), o));
    }

    static Object document(JsonObject vector) throws IOException {
        return JsonTree.parse(vector.getString("document").getBytes(StandardCharsets.UTF_8));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("paths")
    void pathVector(String name, JsonObject vector) throws IOException {
        if (vector.containsKey("error")) {
            assertThatThrownBy(() -> JsonPath.parse(vector.getString("path")))
                    .isInstanceOfSatisfying(JsonPath.PathException.class, e -> assertThat(e.kind().name().toLowerCase(Locale.ROOT))
                            .isEqualTo(vector.getString("error")));
            return;
        }
        JsonPath path = JsonPath.parse(vector.getString("path"));
        List<String> matches = new ArrayList<>();
        for (Object match : path.evaluate(document(vector))) {
            matches.add(JsonTree.compact(match));
        }
        assertThat(matches).containsExactlyElementsOf(vector.getJsonArray("matches").stream().map(String.class::cast).toList());
        assertThat(path.toString()).isEqualTo(vector.getString("path"));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("records")
    void recordVector(String name, JsonObject vector) throws IOException {
        Object document = document(vector);
        List<JsonPath> paths = vector.getJsonArray("paths").stream().map(p -> JsonPath.parse((String) p)).toList();
        List<Map<String, String>> records = new ArrayList<>();
        for (Object record : JsonPath.parse(vector.getString("records_path")).records(document)) {
            Map<String, String> values = new LinkedHashMap<>();
            for (JsonPath path : paths) {
                String value = path.extract(record);
                if (value != null) {
                    values.put(path.source(), value);
                }
            }
            records.add(values);
        }
        JsonArray expected = vector.getJsonArray("records");
        assertThat(records).hasSize(expected.size());
        for (int i = 0; i < expected.size(); i++) {
            assertThat(records.get(i)).as("record %d", i).isEqualTo(expected.getJsonObject(i).getMap());
        }
    }

    @Test
    void definiteness() {
        assertThat(JsonPath.parse("$.a[0]['b']").definite()).isTrue();
        assertThat(JsonPath.parse("$.a[*]").definite()).isFalse();
        assertThat(JsonPath.parse("$..a").definite()).isFalse();
        assertThat(JsonPath.parse("").definite()).isTrue();
    }

    @Test
    void readerRefusesEmptyAndTrailingContent() {
        assertThatThrownBy(() -> JsonTree.parse(new byte[0])).isInstanceOf(IOException.class).hasMessageContaining("empty");
        assertThatThrownBy(() -> JsonTree.parse("{} {}".getBytes(StandardCharsets.UTF_8)))
                .isInstanceOf(IOException.class).hasMessageContaining("after");
        assertThatThrownBy(() -> JsonTree.parse("{".getBytes(StandardCharsets.UTF_8))).isInstanceOf(IOException.class);
    }

    @Test
    void textRendering() throws IOException {
        assertThat(JsonTree.text(JsonTree.NULL)).isNull();
        assertThat(JsonTree.text("plain")).isEqualTo("plain");
        assertThat(JsonTree.text(Boolean.FALSE)).isEqualTo("false");
        assertThat(JsonTree.text(new JsonTree.Num("-0.0"))).isEqualTo("-0.0");
        assertThat(JsonTree.NULL).hasToString("null");
        assertThat(JsonTree.compact(JsonTree.parse("{\"a\":\"\\u001f\"}".getBytes(StandardCharsets.UTF_8))))
                .isEqualTo("{\"a\":\"\\u001f\"}");
        assertThat(JsonPath.parse("$.a").extract(JsonTree.parse("{\"a\":null}".getBytes(StandardCharsets.UTF_8)))).isNull();
    }

    @Test
    void quotedNameEndingInABackslashIsUnterminated() {
        assertThatThrownBy(() -> JsonPath.parse("$['a\\")).isInstanceOfSatisfying(JsonPath.PathException.class,
                e -> assertThat(e.kind()).isEqualTo(JsonPath.Kind.SYNTAX));
    }
}
