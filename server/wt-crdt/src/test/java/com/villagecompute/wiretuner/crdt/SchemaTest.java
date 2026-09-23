package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class SchemaTest {

    @Test
    void generatedTableKnowsTheKindsAndMakesReferencesAtomic() {
        Schema schema = Schema.generated();
        assertThat(schema.kinds()).contains(1, 2, 3, 4, 50, 150);
        assertThat(schema.field("wiretuner.doc.v1.CommonProps", 1).policy()).isEqualTo(Policy.ATOMIC);
        assertThat(schema.field("wiretuner.doc.v1.CommonProps", 8).policy()).isEqualTo(Policy.STRUCT);
        // canvas and style are NodeRefs: ATOMIC in the generated table.
        assertThat(schema.field("wiretuner.doc.v1.CommonProps", 5).policy()).isEqualTo(Policy.ATOMIC);
        assertThat(schema.field("wiretuner.doc.v1.CommonProps", 7).policy()).isEqualTo(Policy.ATOMIC);
        assertThat(schema.field("wiretuner.doc.v1.CommonProps", 999)).isNull();
        assertThat(schema.field("no.Such", 1)).isNull();
        assertThat(schema.fields("no.Such")).isEmpty();
        assertThat(schema.variant("wiretuner.doc.v1.NavigationProps")).isNull();
    }

    @Test
    void tablesAreUsedAsGiven() {
        Schema schema = Tables.shapes();
        assertThat(schema.field("t.K", 8).policy()).isEqualTo(Policy.STRUCT);
        assertThat(schema.fields("t.K")).extracting(row -> row.fieldNumber()).containsExactly(1, 2, 3, 4, 5, 6, 7, 8);
    }

    @Test
    void rowsCanBeAddedToNewAndExistingMessages() {
        Schema schema = Schema.of(Map.of(), Map.of())
                .withField(Schema.ROOT, Tables.row(1000, Policy.STRUCT, "message", false, "t.K", "kind"))
                .withField("t.K", Tables.row(1, Policy.ATOMIC, "string", false, null, null))
                .withField("t.K", Tables.row(1, Policy.SET, "string", true, null, null));
        assertThat(schema.kinds()).containsExactly(1000);
        assertThat(schema.field("t.K", 1).policy()).isEqualTo(Policy.SET);
    }

    @Test
    void overridesReplaceAPolicyOrDeclareAVariant() {
        Schema schema = Schema.generated()
                .withPolicy("wiretuner.doc.v1.CommonProps", 8, Policy.VARIANT)
                .withVariant("wiretuner.doc.v1.NavigationProps", 2, List.of(3));

        assertThat(schema.field("wiretuner.doc.v1.CommonProps", 8).policy()).isEqualTo(Policy.VARIANT);
        assertThat(schema.variant("wiretuner.doc.v1.NavigationProps").caseFields()).containsExactly(3);
        assertThat(schema.kinds()).isEqualTo(Schema.generated().kinds());
        assertThat(Schema.generated().field("wiretuner.doc.v1.CommonProps", 8).policy()).isEqualTo(Policy.STRUCT);
        assertThatThrownBy(() -> schema.withPolicy("wiretuner.doc.v1.CommonProps", 999, Policy.ATOMIC))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("CommonProps.999");
    }

    @Test
    void aTableWithoutNodePropsHasNoKinds() {
        assertThat(Schema.of(Map.of(), Map.of()).kinds()).isEmpty();
    }
}
