package com.villagecompute.wiretuner.api.font;

import static com.villagecompute.wiretuner.api.font.TestFonts.name;
import static com.villagecompute.wiretuner.api.font.TestFonts.os2;
import static com.villagecompute.wiretuner.api.font.TestFonts.sfnt;
import static com.villagecompute.wiretuner.api.font.TestFonts.tables;
import static com.villagecompute.wiretuner.api.font.TestFonts.ttf;
import static com.villagecompute.wiretuner.api.font.TestFonts.win;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.FontFace;
import com.villagecompute.wiretuner.api.PerfReport;
import com.villagecompute.wiretuner.api.PerfTest;
import com.villagecompute.wiretuner.api.font.TestFonts.Name;

/**
 * TXT-002's server half: which files a team font library accepts -- OpenType, TrueType and
 * collections with a cmap, names and outlines -- what it reads from them, and the embedding licence,
 * mirrored bit for bit from WTText's {@code FontEmbedding}.
 */
class FontFilesTest {

    static Map.Entry<Integer, Map<Integer, byte[]>> face(int version, Map<Integer, byte[]> tables) {
        return Map.entry(version, tables);
    }

    static void rejected(byte[] file, String message) {
        assertThatThrownBy(() -> FontFiles.read(file)).isInstanceOf(FontFiles.Rejected.class).hasMessageContaining(message);
    }

    @Test
    void aTrueTypeFontGivesItsNamesAndLicence() {
        FontFiles.Font font = FontFiles.read(ttf("Inter", "Bold Italic", 0x0008));
        assertThat(font.mediaType()).isEqualTo("font/ttf");
        assertThat(font.faces()).containsExactly(FontFace.newBuilder().setFamily("Inter").setStyle("Bold Italic")
                .setPostscriptName("Inter-BoldItalic").setFsType(8).build());
    }

    @Test
    void openTypeAppleTrueTypeAndCff2AreFonts() {
        Map<Integer, byte[]> cff = tables("Source Serif", "Regular", 0);
        cff.remove(FontFiles.GLYF);
        cff.put(FontFiles.CFF, new byte[4]);
        assertThat(FontFiles.read(sfnt(FontFiles.OTTO, cff)).mediaType()).isEqualTo("font/otf");
        assertThat(FontFiles.read(sfnt(FontFiles.TRUE, tables("Chicago", "Regular", 0))).mediaType()).isEqualTo("font/ttf");
        Map<Integer, byte[]> cff2 = tables("Variable", "Regular", 0);
        cff2.remove(FontFiles.GLYF);
        cff2.put(FontFiles.CFF2, new byte[4]);
        assertThat(FontFiles.read(sfnt(FontFiles.OTTO, cff2)).faces().get(0).getFamily()).isEqualTo("Variable");
    }

    @Test
    void aCollectionGivesEveryFace() {
        byte[] file = TestFonts.collection(face(FontFiles.SFNT_1, tables("Avenir", "Book", 0)),
                face(FontFiles.SFNT_1, tables("Avenir", "Heavy", 0)));
        FontFiles.Font font = FontFiles.read(file);
        assertThat(font.mediaType()).isEqualTo("font/collection");
        assertThat(font.faces()).extracting(FontFace::getStyle).containsExactly("Book", "Heavy");
        // One face the licence forbids refuses the whole file.
        rejected(TestFonts.collection(face(FontFiles.SFNT_1, tables("Avenir", "Book", 0)),
                face(FontFiles.SFNT_1, tables("Avenir", "Heavy", 0x0002))), "Avenir-Heavy");
    }

    @Test
    void aCollectionHoldsOneTo256Fonts() {
        ByteBuffer empty = ByteBuffer.allocate(12).putInt(FontFiles.TTCF).putInt(0x00010000).putInt(0);
        rejected(empty.array(), "this one says 0");
        ByteBuffer many = ByteBuffer.allocate(12).putInt(FontFiles.TTCF).putInt(0x00010000).putInt(257);
        rejected(many.array(), "this one says 257");
    }

    @Test
    void theLicenceIsWTTextsDocumentEmbeddingRule() {
        // Installable, editable (also with the restricted bit: the least restrictive bit applies), no subsetting.
        for (int allowed : new int[] {0x0000, 0x0008, 0x000A, 0x000C, 0x0100, 0x0108}) {
            assertThat(FontFiles.allowsDocumentEmbedding(allowed)).as("0x%04x", allowed).isTrue();
            assertThat(FontFiles.read(ttf("Allowed", "Regular", allowed)).faces().get(0).getFsType()).isEqualTo(allowed);
        }
        // Restricted, preview & print, bitmap only.
        for (int refused : new int[] {0x0002, 0x0004, 0x0006, 0x0200, 0x0208}) {
            assertThat(FontFiles.allowsDocumentEmbedding(refused)).as("0x%04x", refused).isFalse();
            rejected(ttf("Refused", "Regular", refused), String.format(Locale.ROOT, "OS/2.fsType 0x%04x", refused));
        }
    }

    @Test
    void aFontWithoutOs2IsInstallable() {
        Map<Integer, byte[]> tables = tables("Old", "Regular", 0x0002);
        tables.remove(FontFiles.OS2);
        assertThat(FontFiles.read(sfnt(FontFiles.SFNT_1, tables)).faces().get(0).getFsType()).isZero();
    }

    @Test
    void typographicNamesWinAndTheBestPlatformIsRead() {
        Map<Integer, byte[]> tables = tables("x", "x", 0);
        tables.put(FontFiles.NAME, name(
                new Name(1, 0, 0, 1, "Café Mac"),
                win(1, "Family Windows"),
                new Name(3, 1, 0x040C, 1, "Famille"),
                new Name(0, 3, 0, 2, "Unicode Style"),
                new Name(1, 0, 0, 2, "Mac Style"),
                new Name(2, 0, 0, 16, "ISO is unreadable"),
                new Name(3, 0, 0x0409, 16, "Symbol is unreadable"),
                new Name(1, 1, 0, 17, "Japanese Mac is unreadable"),
                new Name(3, 10, 0x0409, 16, "Typographic"),
                new Name(3, 1, 0x0409, 17, "Semibold"),
                win(4, "Full name is not read")));
        FontFace face = FontFiles.read(sfnt(FontFiles.SFNT_1, tables)).faces().get(0);
        assertThat(face.getFamily()).isEqualTo("Typographic");
        assertThat(face.getStyle()).isEqualTo("Semibold");
        assertThat(face.getPostscriptName()).isEmpty();

        tables.put(FontFiles.NAME, name(new Name(1, 0, 0, 1, "Café"), new Name(0, 3, 0, 2, "Regular"),
                new Name(1, 0, 0, 2, "Roman")));
        face = FontFiles.read(sfnt(FontFiles.SFNT_1, tables)).faces().get(0);
        assertThat(face.getFamily()).isEqualTo("Café");
        assertThat(face.getStyle()).isEqualTo("Regular");

        // A face with no style and no PostScript name is named by its family in messages.
        tables.put(FontFiles.NAME, name(new Name(3, 1, 0x0407, 1, "Nur Familie")));
        tables.put(FontFiles.OS2, os2(0x0002));
        rejected(sfnt(FontFiles.SFNT_1, tables), "Nur Familie: its licence");
    }

    @Test
    void longNamesAreClippedTo256Characters() {
        FontFace face = FontFiles.read(ttf("F".repeat(300), "Regular", 0)).faces().get(0);
        assertThat(face.getFamily()).hasSize(256);
        assertThat(face.getPostscriptName()).hasSize(256);
    }

    @Test
    void whatIsNotAUsableFontIsRejected() {
        rejected("wOFF not supported".getBytes(), "not an OpenType or TrueType font (it starts with 0x774f4646)");
        rejected(new byte[] {0, 1}, "truncated");
        rejected(ByteBuffer.allocate(12).putInt(FontFiles.SFNT_1).putShort((short) 0).array(), "this one says 0");
        rejected(ByteBuffer.allocate(12).putInt(FontFiles.SFNT_1).putShort((short) 1025).array(), "this one says 1025");

        Map<Integer, byte[]> noCmap = tables("F", "Regular", 0);
        noCmap.remove(FontFiles.CMAP);
        rejected(sfnt(FontFiles.SFNT_1, noCmap), "no cmap or name table");
        Map<Integer, byte[]> noName = tables("F", "Regular", 0);
        noName.remove(FontFiles.NAME);
        rejected(sfnt(FontFiles.SFNT_1, noName), "no cmap or name table");
        Map<Integer, byte[]> noOutlines = tables("F", "Regular", 0);
        noOutlines.remove(FontFiles.GLYF);
        rejected(sfnt(FontFiles.SFNT_1, noOutlines), "no outlines");
        Map<Integer, byte[]> noFamily = tables("F", "Regular", 0);
        noFamily.put(FontFiles.NAME, name(win(2, "Regular")));
        rejected(sfnt(FontFiles.SFNT_1, noFamily), "no family name");
    }

    @Test
    void offsetsOutsideTheFileAreMalformed() {
        byte[] file = ttf("F", "Regular", 0);
        // The name table's offset (third record) past the int range, then past the end of the file.
        ByteBuffer.wrap(file).putInt(12 + 16 * 2 + 8, 0xFFFFFFF0);
        rejected(file, "truncated");
        ByteBuffer.wrap(file).putInt(12 + 16 * 2 + 8, file.length + 100);
        rejected(file, "truncated");
        // A name string past the end.
        byte[] strings = ttf("F", "Regular", 0);
        int name = ByteBuffer.wrap(strings).getInt(12 + 16 * 2 + 8);
        ByteBuffer.wrap(strings).putShort(name + 6 + 10, (short) 0x7FFF);
        rejected(strings, "truncated");
        // A collection whose offset table is cut short.
        rejected(ByteBuffer.allocate(12).putInt(FontFiles.TTCF).putInt(0x00010000).putInt(2).array(), "truncated");
    }

    @PerfTest
    void readingA256FaceCollectionIsUnder50Ms() {
        List<Map.Entry<Integer, Map<Integer, byte[]>>> faces = new ArrayList<>();
        for (int i = 0; i < 256; i++) {
            faces.add(face(FontFiles.SFNT_1, tables("Family " + i, "Style " + i, 0)));
        }
        @SuppressWarnings("unchecked")
        byte[] file = TestFonts.collection(faces.toArray(Map.Entry[]::new));
        FontFiles.read(file);
        long started = System.nanoTime();
        FontFiles.Font font = FontFiles.read(file);
        long elapsed = System.nanoTime() - started;
        assertThat(font.faces()).hasSize(256);
        PerfReport.measured("FontFiles.read, 256-face collection (TXT-002)",
                String.format(Locale.ROOT, "%.1f ms", elapsed / 1e6), "< 50 ms",
                elapsed < TimeUnit.MILLISECONDS.toNanos(50));
        assertThat(elapsed).isLessThan(TimeUnit.MILLISECONDS.toNanos(50));
    }
}
