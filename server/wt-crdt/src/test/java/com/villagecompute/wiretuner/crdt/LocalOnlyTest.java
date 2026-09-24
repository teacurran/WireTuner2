package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.HtmlSetting;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Local-only fields (docs/spec/crdt-model.adoc, "Local-only fields"), mirroring WTCRDTTests'
 * {@code LocalOnlyTests}: a write to one is a no-op here, and {@link LocalOnly#strip} takes it out
 * of a change. The {@code registers/local-only-*} vectors check both engines agree.
 */
class LocalOnlyTest {

    static final OpId SETTINGS = OpId.wellKnown(1);
    static final RegisterPath MAGNIFICATION = RegisterPath.of(2, 40, 1);
    static final OpId ASSET = new OpId(1, 7);
    static final String SETTINGS_NODE = "node { counter: 1 }";
    static final Schema SCHEMA = Schema.generated();

    static String path(int... fields) {
        StringBuilder out = new StringBuilder();
        for (int field : fields) {
            out.append("segments { field: ").append(field).append(" } ");
        }
        return out.toString();
    }

    static String element(OpId id) {
        return "segments { element { counter: " + id.counter() + " replica: " + id.replica() + " } } ";
    }

    static Change zoom(long replica, long counter) {
        return Scenario.change(replica, 1, counter,
                "set { " + SETTINGS_NODE + " paths { " + path(2, 40, 1) + "} values { settings { view { magnification: 2 } } } }");
    }

    @Test
    void writesToLocalOnlyRegistersAreNoOps() {
        Engine engine = new Engine(Scenario.SCHEMA);
        byte[] before = engine.stateHash();
        engine.apply(zoom(2, 1), 1L);
        assertThat(engine.register(SETTINGS, MAGNIFICATION)).isNull();
        assertThat(engine.stateHash()).isEqualTo(before);
        // Even the replica's own change, applied locally, does not write one here.
        engine.applyLocal(zoom(7, 2));
        assertThat(engine.register(SETTINGS, MAGNIFICATION)).isNull();

        Engine mixed = new Engine(Scenario.SCHEMA);
        mixed.apply(Scenario.change(7, 1, 1, "set { " + SETTINGS_NODE + " paths { " + path(2, 40, 1) + "} paths { " + path(2, 7)
                + "} values { settings { view { magnification: 2 } guides_locked: true } } }"));
        assertThat(mixed.register(SETTINGS, MAGNIFICATION)).isNull();
        assertThat(mixed.register(SETTINGS, RegisterPath.of(2, 7))).isNotNull();
        mixed.apply(Scenario.change(7, 2, 2, "set { " + SETTINGS_NODE + " paths { " + path(2) + "} values { settings { } } }"));
        assertThat(mixed.register(SETTINGS, MAGNIFICATION)).isNull();

        Engine created = new Engine(Scenario.SCHEMA);
        created.apply(Scenario.change(7, 1, 1,
                "create { parent { counter: 4 } position: \"\\x80\" props { asset { common { name: \"a\" } bookmark: \"\\x01\" } } }"));
        assertThat(created.register(ASSET, RegisterPath.of(5, 6))).isNull();
        assertThat(created.register(ASSET, RegisterPath.of(5, 1, 1))).isNotNull();
        created.apply(Scenario.change(7, 2, 2, "element_insert { " + SETTINGS_NODE + " sequence { " + path(2, 60)
                + "} positions: \"\\x80\" values { settings { html_settings { name: \"W\" location: \"/w\" } } } }"));
        RegisterPath setting = RegisterPath.of(2, 60).element(new OpId(2, 7));
        assertThat(created.register(SETTINGS, setting.child(3))).isNull();
        assertThat(created.register(SETTINGS, setting.child(2))).isNotNull();
    }

    @Test
    void enteringALocalOnlyFieldIsReadFromTheTable() {
        assertThat(LocalOnly.enters(SCHEMA, MAGNIFICATION)).isTrue();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(2, 61))).isTrue();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(5, 6))).isTrue();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(2, 60).element(new OpId(3, 7)).child(3))).isTrue();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(2, 60).element(new OpId(3, 7)).child(2))).isFalse();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(2))).isFalse();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(2, 30, 1))).isFalse();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(2, 9999))).isFalse();
        assertThat(LocalOnly.enters(SCHEMA, RegisterPath.of(9999, 1))).isFalse();
        assertThat(LocalOnly.enters(SCHEMA, MAGNIFICATION.toProto())).isTrue();
        FieldPath malformed = FieldPath.newBuilder().addSegments(PathSegment.getDefaultInstance()).build();
        assertThat(LocalOnly.enters(SCHEMA, malformed)).isFalse();
    }

    @Test
    void stripDropsLocalOnlyPathsAndValues() {
        Change stripped = LocalOnly.strip(SCHEMA, zoom(7, 1));
        assertThat(stripped.getOps(0)).isEqualTo(Op.newBuilder().setNoop(Noop.getDefaultInstance()).build());
        assertThat(LocalOnly.carries(SCHEMA, zoom(7, 1))).isTrue();

        Change mixed = Scenario.change(7, 1, 1, "set { " + SETTINGS_NODE + " paths { " + path(2, 40, 1) + "} paths { " + path(2, 7)
                + "} values { settings { view { magnification: 2 } guides_locked: true } } }", "noop { }");
        Change split = LocalOnly.strip(SCHEMA, mixed);
        assertThat(split.getOps(0).getSet().getPathsList()).containsExactly(RegisterPath.of(2, 7).toProto());
        assertThat(split.getOps(0).getSet().getValues().getSettings().hasView()).isFalse();
        assertThat(split.getOps(0).getSet().getValues().getSettings().getGuidesLocked()).isTrue();
        assertThat(split.getOps(1)).isEqualTo(mixed.getOps(1));
        assertThat(LocalOnly.carries(SCHEMA, split)).isFalse();

        Change create = Scenario.change(7, 1, 1,
                "create { parent { counter: 4 } position: \"\\x80\" props { asset { common { name: \"a\" } bookmark: \"\\x01\" } } }");
        NodeProps props = LocalOnly.strip(SCHEMA, create).getOps(0).getCreate().getProps();
        assertThat(props.getAsset().getBookmark().isEmpty()).isTrue();
        assertThat(props.getAsset().getCommon().getName()).isEqualTo("a");

        Change insert = Scenario.change(7, 1, 1, "element_insert { " + SETTINGS_NODE + " sequence { " + path(2, 60)
                + "} positions: \"\\x80\" positions: \"\\x81\" values { settings { html_settings { id { counter: 9 } name: \"A\" location: \"/a\" }"
                + " html_settings { name: \"B\" } } } }");
        List<HtmlSetting> inserted = LocalOnly.strip(SCHEMA, insert).getOps(0).getElementInsert().getValues().getSettings().getHtmlSettingsList();
        assertThat(inserted).extracting(HtmlSetting::getLocation).containsExactly("", "");
        assertThat(inserted).extracting(HtmlSetting::getName).containsExactly("A", "B");
        assertThat(inserted.get(0).getId().getCounter()).isEqualTo(9);

        Change clear = Scenario.change(7, 1, 1, "set { " + SETTINGS_NODE + " paths { " + path(2, 61) + "} }");
        assertThat(LocalOnly.strip(SCHEMA, clear).getOps(0).hasNoop()).isTrue();
    }

    @Test
    void stripLeavesEverythingElseAsItCame() {
        Change plain = Scenario.change(7, 1, 1,
                "set { " + SETTINGS_NODE + " paths { " + path(2, 7) + "} values { settings { guides_locked: true } } }",
                "set_add { node { counter: 1 replica: 7 } set { " + path(1000, 3) + "} values { test { tags: \"x\" } } }",
                "set_remove { node { counter: 1 replica: 7 } set { " + path(1000, 3) + "} values { test { tags: \"x\" } } }",
                "set { " + SETTINGS_NODE + " }",
                "move { node { counter: 1 replica: 7 } parent { counter: 4 } }");
        assertThat(LocalOnly.strip(SCHEMA, plain)).isSameAs(plain);
        assertThat(LocalOnly.carries(SCHEMA, plain)).isFalse();
        assertThat(LocalOnly.strip(SCHEMA, new byte[] {0x0B})).isNull();
        Change malformed = Changes.change(7, 1, Changes.set(SETTINGS, Changes.raw(Wire.message().bytes(1000, new byte[] {0x0B}).build()),
                RegisterPath.of(2, 7)));
        assertThat(LocalOnly.strip(Scenario.SCHEMA, malformed)).isSameAs(malformed);
    }

    @Test
    void stripReachesSetOpsAndTextCharacters() throws InvalidProtocolBufferException {
        String paragraph = "wiretuner.conformance.v1.TestParagraph";
        String test = "wiretuner.conformance.v1.TestProps";
        Schema schema = Scenario.SCHEMA.withField(paragraph, local(Scenario.SCHEMA.field(paragraph, 4)))
                .withField(test, local(Scenario.SCHEMA.field(test, 2)));
        OpId character = new OpId(5, 7);
        String text = "set { node { counter: 1 replica: 7 } paths { " + path(1000, 9) + element(character) + path(6, 4) + "} "
                + "values { test { text { chars { id { counter: 5 replica: 7 } codepoint: 10 paragraph { left_indent: 3 space_above: 2 } } "
                + "marks { id { counter: 6 } } } } } }";
        String add = "set_add { node { counter: 1 replica: 7 } set { " + path(1000, 3) + "} values { test { tags: \"x\" label: \"l\" } } }";
        String remove = "set_remove { node { counter: 1 replica: 7 } set { " + path(1000, 3) + "} values { test { tags: \"x\" label: \"l\" } } }";
        Change change = Scenario.change(7, 1, 1, text, add, remove);
        Change stripped = LocalOnly.strip(schema, change);
        assertThat(stripped.getOps(0).hasNoop()).isTrue();
        var added = com.villagecompute.wiretuner.conformance.v1.NodeProps.parseFrom(stripped.getOps(1).getSetAdd().getValues().toByteArray());
        assertThat(added.getTest().getTagsList()).containsExactly("x");
        assertThat(added.getTest().getLabel()).isEmpty();
        var removed = com.villagecompute.wiretuner.conformance.v1.NodeProps.parseFrom(stripped.getOps(2).getSetRemove().getValues().toByteArray());
        assertThat(removed.getTest().getLabel()).isEmpty();
        byte[] props = LocalOnly.strip(schema, change.getOps(0).getSet().getValues().toByteArray());
        var chars = com.villagecompute.wiretuner.conformance.v1.NodeProps.parseFrom(props).getTest().getText();
        assertThat(chars.getChars(0).getCodepoint()).isEqualTo(10);
        assertThat(chars.getChars(0).getParagraph().getLeftIndent()).isZero();
        assertThat(chars.getChars(0).getParagraph().getSpaceAbove()).isEqualTo(2);
        assertThat(chars.getMarksCount()).isEqualTo(1);
        String plain = "set { node { counter: 1 replica: 7 } paths { " + path(1000, 9) + element(character) + path(6, 7) + "} "
                + "values { test { text { chars { id { counter: 5 replica: 7 } paragraph { space_above: 2 } } } } } }";
        Change kept = Scenario.change(7, 1, 1, plain);
        assertThat(LocalOnly.strip(schema, kept)).isSameAs(kept);
    }

    static FieldPolicy local(FieldPolicy row) {
        return new FieldPolicy(row.fieldNumber(), row.name(), row.policy(), row.onDangling(), true, row.type(), row.repeated(),
                row.typeName(), row.elementMessage(), row.oneof());
    }

}
