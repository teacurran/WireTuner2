package com.villagecompute.wiretuner.api.library;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.api.history.SearchExtractor;
import com.villagecompute.wiretuner.crdt.Cell;
import com.villagecompute.wiretuner.crdt.NodeStore;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.crdt.RegisterPath;
import com.villagecompute.wiretuner.doc.v1.Color;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.NodeRef;
import com.villagecompute.wiretuner.doc.v1.SwatchProps;
import com.villagecompute.wiretuner.doc.v1.SwatchRole;
import com.villagecompute.wiretuner.lib.v1.ColorLibrary;
import com.villagecompute.wiretuner.lib.v1.LibraryColor;

/**
 * A team color library's colors from a document's merged state (COLOR-020; exporting-colors.adoc,
 * Server), read through the generic node tree like the search record: the children of the swatches
 * collection (0:5) in list order that are live color or tint swatches, the protected defaults
 * (White, Black, Registration) left out. Each color's key is its swatch's node id; a tint carries
 * its base's color and, when the base is in the library, the base's key. No color is computed: a
 * tint's mix toward white is the client's (tints.adoc).
 */
public final class ColorLibraries {

    /** The swatches collection, 0:5. */
    static final OpId SWATCHES = OpId.wellKnown(5);

    static final int KIND = NodeProps.SWATCH_FIELD_NUMBER;
    static final RegisterPath NAME = RegisterPath.of(KIND, SwatchProps.COMMON_FIELD_NUMBER, CommonProps.NAME_FIELD_NUMBER);
    static final RegisterPath VALUE = RegisterPath.of(KIND, SwatchProps.VALUE_FIELD_NUMBER);
    static final RegisterPath SPOT = RegisterPath.of(KIND, SwatchProps.SPOT_FIELD_NUMBER);
    static final RegisterPath PARENT = RegisterPath.of(KIND, SwatchProps.PARENT_FIELD_NUMBER);
    static final RegisterPath TINT = RegisterPath.of(KIND, SwatchProps.TINT_PERCENT_FIELD_NUMBER);
    static final RegisterPath ROLE = RegisterPath.of(KIND, SwatchProps.ROLE_FIELD_NUMBER);
    static final RegisterPath GROUP = RegisterPath.of(KIND, SwatchProps.GROUP_FIELD_NUMBER);

    /** A color being built, with its tint's base reference (null for a color). */
    private record Entry(LibraryColor.Builder color, NodeRef parent) {
    }

    private ColorLibraries() {
    }

    /** The colors of {@code store} as a library named {@code name}. */
    public static ColorLibrary extract(NodeStore store, String name) {
        Map<OpId, LibraryColor> bases = new HashMap<>();
        List<Entry> entries = new ArrayList<>();
        for (OpId node : store.children(SWATCHES)) {
            if (store.kind(node) != KIND || deleted(store, node)
                    || read(store, node, ROLE).getRole() != SwatchRole.SWATCH_ROLE_UNSPECIFIED) {
                continue;
            }
            LibraryColor.Builder color = LibraryColor.newBuilder()
                    .setKey(node.toString())
                    .setName(SearchExtractor.parse(SearchExtractor.value(store, node, NAME), CommonProps.getDefaultInstance())
                            .getName())
                    .setSpot(read(store, node, SPOT).getSpot())
                    .setGroup(read(store, node, GROUP).getGroup());
            NodeRef parent = read(store, node, PARENT).getParent();
            if (parent.hasId()) {
                double percent = read(store, node, TINT).getTintPercent();
                color.setTintPercent(percent == 0 ? 100 : percent);
                entries.add(new Entry(color, parent));
            } else {
                color.setValue(read(store, node, VALUE).getValue());
                bases.put(node, color.build());
                entries.add(new Entry(color, null));
            }
        }
        ColorLibrary.Builder library = ColorLibrary.newBuilder().setName(name);
        for (Entry entry : entries) {
            LibraryColor.Builder color = entry.color();
            NodeRef parent = entry.parent();
            if (parent != null) {
                LibraryColor base = bases.get(OpId.of(parent.getId()));
                if (base != null) {
                    color.setTintOf(base.getKey()).setValue(base.getValue());
                } else {
                    color.setValue(cached(parent));
                }
            }
            library.addColors(color);
        }
        return library.build();
    }

    static boolean deleted(NodeStore store, OpId node) {
        Cell<Boolean> deleted = store.deleted(node);
        return deleted != null && deleted.current().value();
    }

    /** The swatch register at {@code path}, as the {@code SwatchProps} holding only it. */
    static SwatchProps read(NodeStore store, OpId node, RegisterPath path) {
        return SearchExtractor.parse(SearchExtractor.value(store, node, path), SwatchProps.getDefaultInstance());
    }

    /** The base color a tint cached when it was written; the default color when it holds none that parses. */
    static Color cached(NodeRef parent) {
        try {
            return Color.parseFrom(parent.getCached());
        } catch (InvalidProtocolBufferException e) {
            return Color.getDefaultInstance();
        }
    }
}
