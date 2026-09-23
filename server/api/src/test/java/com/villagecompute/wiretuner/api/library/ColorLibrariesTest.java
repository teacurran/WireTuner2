package com.villagecompute.wiretuner.api.library;

import static com.villagecompute.wiretuner.api.library.SwatchOps.cmyk;
import static com.villagecompute.wiretuner.api.library.SwatchOps.color;
import static com.villagecompute.wiretuner.api.library.SwatchOps.defaultSwatch;
import static com.villagecompute.wiretuner.api.library.SwatchOps.recolor;
import static com.villagecompute.wiretuner.api.library.SwatchOps.rgb;
import static com.villagecompute.wiretuner.api.library.SwatchOps.tint;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.history.DocOps;
import com.villagecompute.wiretuner.api.history.DocOps.Author;
import com.villagecompute.wiretuner.api.persistence.TeamColorLibraryRepository.Listed;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Color;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.SwatchRole;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryInfo;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryMode;
import com.villagecompute.wiretuner.lib.v1.ColorLibrary;
import com.villagecompute.wiretuner.lib.v1.LibraryColor;

/** COLOR-020: the colors of a merged state, and the listing's version rules, without a server. */
class ColorLibrariesTest {

    static ColorLibrary extract(List<Change> changes) {
        Engine engine = new Engine();
        for (int i = 0; i < changes.size(); i++) {
            engine.apply(changes.get(i), (long) i + 1);
        }
        return ColorLibraries.extract(engine.store(), "Brand");
    }

    static String key(OpId id) {
        return Long.toUnsignedString(id.getCounter()) + ":" + Long.toUnsignedString(id.getReplica());
    }

    @Test
    void colorsAndTintsInListOrderWithoutDefaultsOrDeletedSwatches() {
        Author author = new Author(3L);
        OpId white = author.next();
        Change defaults = author.change("defaults", defaultSwatch("White", SwatchRole.SWATCH_ROLE_WHITE),
                defaultSwatch("Registration", SwatchRole.SWATCH_ROLE_REGISTRATION));
        OpId grape = author.next();
        Change first = author.change("grape", color("Grape", rgb(0.4, 0.1, 0.6), false, "Fruit"));
        OpId pms = author.next();
        Change second = author.change("pms", color("PANTONE 300 C", cmyk(1, 0.44, 0, 0), true, ""));
        OpId gone = author.next();
        Change third = author.change("gone", color("Gone", rgb(1, 1, 1), false, ""));
        OpId tinted = author.next();
        Change fourth = author.change("tints",
                tint("40% Grape", grape, Color.getDefaultInstance().toByteString(), 40),
                tint("Full Grape", grape, ByteString.EMPTY, 0),
                tint("Orphan", gone, rgb(1, 1, 1).toByteString(), 25),
                tint("Broken", OpId.newBuilder().setCounter(999).setReplica(9).build(),
                        ByteString.copyFrom(new byte[] {(byte) 0xff, (byte) 0xff}), 10),
                DocOps.create(SwatchOps.SWATCHES, DocOps.style("Not a swatch")));
        Change fifth = author.change("edits", DocOps.delete(gone), recolor(grape, rgb(0.5, 0.1, 0.6)), DocOps.delete(pms));
        Change sixth = author.change("undo", DocOps.undelete(pms));

        ColorLibrary library = extract(List.of(defaults, first, second, third, fourth, fifth, sixth));

        assertThat(white.getCounter()).isPositive();
        assertThat(library.getName()).isEqualTo("Brand");
        assertThat(library.getColorsList()).extracting(LibraryColor::getName)
                .containsExactly("Grape", "PANTONE 300 C", "40% Grape", "Full Grape", "Orphan", "Broken");
        LibraryColor grapeColor = library.getColors(0);
        assertThat(grapeColor.getKey()).isEqualTo(key(grape));
        assertThat(grapeColor.getValue()).isEqualTo(rgb(0.5, 0.1, 0.6));
        assertThat(grapeColor.getGroup()).isEqualTo("Fruit");
        assertThat(grapeColor.getSpot()).isFalse();
        assertThat(grapeColor.getTintPercent()).isZero();
        assertThat(library.getColors(1).getSpot()).isTrue();
        assertThat(library.getColors(1).getKey()).isEqualTo(key(pms));
        // A tint of a base in the library carries the base's current color and key.
        LibraryColor forty = library.getColors(2);
        assertThat(forty.getKey()).isEqualTo(key(tinted));
        assertThat(forty.getTintOf()).isEqualTo(key(grape));
        assertThat(forty.getValue()).isEqualTo(rgb(0.5, 0.1, 0.6));
        assertThat(forty.getTintPercent()).isEqualTo(40);
        assertThat(library.getColors(3).getTintPercent()).isEqualTo(100);
        // A tint whose base is gone carries the color it cached; one whose cache does not parse, the default.
        assertThat(library.getColors(4).getTintOf()).isEmpty();
        assertThat(library.getColors(4).getValue()).isEqualTo(rgb(1, 1, 1));
        assertThat(library.getColors(5).getValue()).isEqualTo(Color.getDefaultInstance());
    }

    @Test
    void anEmptyDocumentHasNoColors() {
        assertThat(extract(List.of()).getColorsList()).isEmpty();
    }

    @Test
    void automaticLibrariesPublishTheHeadAndDateFromItsChange() {
        java.util.UUID doc = java.util.UUID.randomUUID();
        java.util.UUID team = java.util.UUID.randomUUID();
        ColorLibraryInfo automatic = ColorLibraryGrpcService.info(new Listed(doc, team, "Brand", false, 0, null, 1000, 7, 2000L));
        assertThat(automatic.getPublishedSeq()).isEqualTo(7);
        assertThat(automatic.getUpdatedMs()).isEqualTo(2000);
        assertThat(automatic.getMode()).isEqualTo(ColorLibraryMode.COLOR_LIBRARY_MODE_AUTOMATIC);
        assertThat(automatic.getPublishedByAccountId()).isEmpty();
        // Republished after the head change, or with the head compacted away: the publish time.
        assertThat(ColorLibraryGrpcService.info(new Listed(doc, team, "Brand", false, 0, team, 3000, 7, 2000L)).getUpdatedMs())
                .isEqualTo(3000);
        assertThat(ColorLibraryGrpcService.info(new Listed(doc, team, "Brand", false, 0, team, 1000, 7, null)).getUpdatedMs())
                .isEqualTo(1000);
        ColorLibraryInfo manual = ColorLibraryGrpcService.info(new Listed(doc, team, "Brand", true, 3, team, 1000, 7, 2000L));
        assertThat(manual.getPublishedSeq()).isEqualTo(3);
        assertThat(manual.getUpdatedMs()).isEqualTo(1000);
        assertThat(manual.getMode()).isEqualTo(ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL);
        assertThat(manual.getPublishedByAccountId()).isEqualTo(team.toString());
    }

    @Test
    void storedColorsThatDoNotParseAreACorruptRow() {
        assertThat(ColorLibraryGrpcService.decode(ColorLibrary.newBuilder().setName("x").build().toByteArray()).getName())
                .isEqualTo("x");
        assertThatThrownBy(() -> ColorLibraryGrpcService.decode(new byte[] {(byte) 0xff, (byte) 0xff}))
                .isInstanceOf(IllegalStateException.class);
    }
}
