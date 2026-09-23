package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.LayerProps;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import org.junit.jupiter.api.Test;

class RegisterPathTest {

    @Test
    void encodesCanonicallyAndOrdersSegmentWise() {
        RegisterPath name = RegisterPath.of(150, 1, 1);
        assertThat(name.canonical()).containsExactly(1, 0, 0, 0, (byte) 150, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1);
        assertThat(RegisterPath.of(150, 1)).isLessThan(name);
        assertThat(RegisterPath.of(150, 1, 13, 2)).isGreaterThan(RegisterPath.of(150, 1, 2));
        assertThat(RegisterPath.of(150, 1, 256)).isGreaterThan(RegisterPath.of(150, 1, 255));
        assertThat(RegisterPath.of(150, 1).child(1)).isEqualTo(name).hasSameHashCodeAs(name);
        assertThat(name).isNotEqualTo("150.1.1").hasToString("150.1.1");
        assertThat(name.fields()).containsExactly(150, 1, 1);
    }

    @Test
    void convertsFieldPaths() {
        RegisterPath path = RegisterPath.of(150, 1, 6);
        assertThat(RegisterPath.of(path.toProto())).isEqualTo(path);
        assertThat(RegisterPath.of(FieldPath.getDefaultInstance())).isNull();
        FieldPath withElement = path.toProto().toBuilder()
                .addSegments(PathSegment.newBuilder().setElement(ElementId.newBuilder().setCounter(3).setReplica(1)))
                .build();
        RegisterPath element = RegisterPath.of(withElement);
        assertThat(element).isEqualTo(path.element(new OpId(3, 1))).hasToString("150.1.6.<3:1>");
        assertThat(element.toProto()).isEqualTo(withElement);
        assertThat(element.parent()).isEqualTo(path);
        assertThat(element.last().isElement()).isTrue();
        assertThat(element.fields()).containsExactly(150, 1, 6);
        assertThat(element.segments()).hasSize(4);
        assertThat(RegisterPath.of(150).parent()).isNull();
        assertThat(RegisterPath.of(path.toProto().toBuilder().addSegments(PathSegment.getDefaultInstance()).build()))
                .isNull();
        assertThat(element.canonical()).hasSize(15 + 17).endsWith(0x02, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 1);
        assertThat(RegisterPath.of(150, 1, 6, 1)).isLessThan(element);
        assertThatThrownBy(() -> RegisterPath.of(java.util.List.of())).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(RegisterPath::of).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void readsTheValueAPathAddressesInAMessage() {
        byte[] props = NodeProps.newBuilder()
                .setLayer(LayerProps.newBuilder().setCommon(CommonProps.newBuilder().setName("A").setLocked(true)))
                .build().toByteArray();

        assertThat(RegisterPath.of(150, 1, 1).valueIn(props)).isEqualTo(Wire.message().string(1, "A").build());
        assertThat(RegisterPath.of(150, 1, 2).valueIn(props)).isNull();
        assertThat(RegisterPath.of(3, 1, 1).valueIn(props)).isNull();
        assertThat(RegisterPath.of(150).valueIn(props)).isNotNull();
        assertThat(RegisterPath.of(1).valueIn(new byte[] {0x0F})).isNull();
        assertThat(RegisterPath.of(150, 1).element(new OpId(1, 1)).child(1).valueIn(props))
                .as("element segments are transparent").isEqualTo(Wire.message().string(1, "A").build());
        assertThat(RegisterPath.of(java.util.List.of(RegisterPath.Segment.element(OpId.ZERO))).valueIn(props)).isNull();
    }
}
