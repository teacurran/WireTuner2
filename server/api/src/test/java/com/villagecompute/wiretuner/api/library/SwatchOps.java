package com.villagecompute.wiretuner.api.library;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.history.DocOps;
import com.villagecompute.wiretuner.doc.v1.Cmyk;
import com.villagecompute.wiretuner.doc.v1.Color;
import com.villagecompute.wiretuner.doc.v1.ColorSpace;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.NodeRef;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.Rgb;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.SwatchProps;
import com.villagecompute.wiretuner.doc.v1.SwatchRole;

/** Swatch ops as a client writes them, for the color library tests (COLOR-020). */
final class SwatchOps {

    static final OpId SWATCHES = DocOps.wellKnown(DocOps.SWATCHES);

    private SwatchOps() {
    }

    static Color rgb(double r, double g, double b) {
        return Color.newBuilder().setRgb(Rgb.newBuilder().setR(r).setG(g).setB(b)).setSpace(ColorSpace.COLOR_SPACE_SRGB)
                .build();
    }

    static Color cmyk(double c, double m, double y, double k) {
        return Color.newBuilder().setCmyk(Cmyk.newBuilder().setC(c).setM(m).setY(y).setK(k)).build();
    }

    /** Creates a color swatch in the swatches collection. */
    static Op color(String name, Color value, boolean spot, String group) {
        return DocOps.create(SWATCHES, NodeProps.newBuilder().setSwatch(SwatchProps.newBuilder()
                .setCommon(CommonProps.newBuilder().setName(name)).setValue(value).setSpot(spot).setGroup(group)).build());
    }

    /** Creates a protected default swatch. */
    static Op defaultSwatch(String name, SwatchRole role) {
        return DocOps.create(SWATCHES, NodeProps.newBuilder().setSwatch(SwatchProps.newBuilder()
                .setCommon(CommonProps.newBuilder().setName(name)).setValue(cmyk(0, 0, 0, 1)).setRole(role)).build());
    }

    /** Creates a tint of {@code base} caching {@code cached} (raw bytes) as the base's color; percent 0 = never set. */
    static Op tint(String name, OpId base, ByteString cached, double percent) {
        return DocOps.create(SWATCHES, NodeProps.newBuilder().setSwatch(SwatchProps.newBuilder()
                .setCommon(CommonProps.newBuilder().setName(name))
                .setParent(NodeRef.newBuilder().setId(base).setCached(cached)).setTintPercent(percent)).build());
    }

    /** Recolors a swatch (writes {@code swatch.value}). */
    static Op recolor(OpId swatch, Color value) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(swatch)
                .addPaths(DocOps.fields(NodeProps.SWATCH_FIELD_NUMBER, SwatchProps.VALUE_FIELD_NUMBER))
                .setValues(NodeProps.newBuilder().setSwatch(SwatchProps.newBuilder().setValue(value)))).build();
    }
}
