package com.villagecompute.wiretuner.api.font;

import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import com.villagecompute.wiretuner.account.v1.FontFace;

/**
 * Reads what a team font library needs from a font file (TXT-002's server half;
 * font-substitution.adoc, Server): whether it is an OpenType ({@code OTTO}), TrueType
 * ({@code 0x00010000}, {@code true}) or TrueType collection ({@code ttcf}) with outlines, each face's
 * names and its {@code OS/2.fsType}, and whether that licence allows the file to be shared. The
 * licence rule is WTText's {@code FontEmbedding.allowsDocumentEmbedding}: the least restrictive usage
 * bit applies, installable (no bit) or editable (bit 3) passes, and bitmap-only (bit 9) fails; a face
 * with no OS/2 table is installable. Nothing is rendered; only the table directory, {@code name} and
 * {@code OS/2} are read, and every offset is bounds-checked, so a hostile file fails as malformed.
 */
public final class FontFiles {

    static final int TTCF = 0x74746366;
    static final int OTTO = 0x4F54544F;
    static final int TRUE = 0x74727565;
    static final int SFNT_1 = 0x00010000;

    static final int NAME = 0x6E616D65;
    static final int OS2 = 0x4F532F32;
    static final int CMAP = 0x636D6170;
    static final int GLYF = 0x676C7966;
    static final int CFF = 0x43464620;
    static final int CFF2 = 0x43464632;

    /** A collection holds at most this many faces (the proto's cap). */
    static final int MAX_FACES = 256;
    /** A face holds at most this many tables. */
    static final int MAX_TABLES = 1024;

    static final String OTF = "font/otf";
    static final String TTF = "font/ttf";
    static final String COLLECTION = "font/collection";

    private static final Charset MAC_ROMAN = Charset.forName("x-MacRoman");

    /** A readable font file: its media type and its faces in file order. */
    public record Font(String mediaType, List<FontFace> faces) {
    }

    /** Why a file is not accepted; the message is for the admin who uploaded it. */
    public static final class Rejected extends RuntimeException {

        private static final long serialVersionUID = 1L;

        Rejected(String message) {
            super(message);
        }
    }

    private FontFiles() {
    }

    /** The file's faces, each allowed to be shared; {@link Rejected} otherwise. */
    public static Font read(byte[] bytes) {
        ByteBuffer file = ByteBuffer.wrap(bytes);
        try {
            int tag = file.getInt(0);
            if (tag == TTCF) {
                long count = u32(file, 8);
                if (count == 0 || count > MAX_FACES) {
                    throw new Rejected("a font collection holds 1 to " + MAX_FACES + " fonts; this one says " + count);
                }
                List<FontFace> faces = new ArrayList<>();
                for (int i = 0; i < count; i++) {
                    faces.add(face(file, offset(file, 12 + 4 * i)));
                }
                return new Font(COLLECTION, faces);
            }
            return new Font(tag == OTTO ? OTF : TTF, List.of(face(file, 0)));
        } catch (IndexOutOfBoundsException e) {
            throw new Rejected("the file is truncated, or its tables point outside it");
        }
    }

    /** One face's names and licence, from the table directory at {@code at}. */
    static FontFace face(ByteBuffer file, int at) {
        int version = file.getInt(at);
        if (version != SFNT_1 && version != OTTO && version != TRUE) {
            throw new Rejected("not an OpenType or TrueType font (it starts with 0x"
                    + String.format(Locale.ROOT, "%08x", version) + ")");
        }
        int count = u16(file, at + 4);
        if (count == 0 || count > MAX_TABLES) {
            throw new Rejected("a font holds 1 to " + MAX_TABLES + " tables; this one says " + count);
        }
        Map<Integer, Integer> tables = new HashMap<>();
        for (int i = 0; i < count; i++) {
            int record = at + 12 + 16 * i;
            tables.put(file.getInt(record), offset(file, record + 8));
        }
        if (!tables.containsKey(CMAP) || !tables.containsKey(NAME)) {
            throw new Rejected("the font has no cmap or name table");
        }
        if (!tables.containsKey(GLYF) && !tables.containsKey(CFF) && !tables.containsKey(CFF2)) {
            throw new Rejected("the font has no outlines (glyf, CFF or CFF2)");
        }
        Map<Integer, String> names = names(file, tables.get(NAME));
        String family = names.getOrDefault(16, names.getOrDefault(1, ""));
        if (family.isEmpty()) {
            throw new Rejected("the font has no family name");
        }
        String style = names.getOrDefault(17, names.getOrDefault(2, ""));
        String postscript = names.getOrDefault(6, "");
        Integer os2 = tables.get(OS2);
        int fsType = os2 == null ? 0 : u16(file, os2 + 8);
        FontFace face = FontFace.newBuilder().setFamily(clip(family)).setStyle(clip(style))
                .setPostscriptName(clip(postscript)).setFsType(fsType).build();
        if (!allowsDocumentEmbedding(fsType)) {
            throw new Rejected(label(face) + ": its licence (OS/2.fsType 0x"
                    + String.format(Locale.ROOT, "%04x", fsType)
                    + ") does not allow embedding it in documents others edit, so it cannot be shared");
        }
        return face;
    }

    /**
     * WTText's {@code FontEmbedding.allowsDocumentEmbedding}: installable (no usage bit) or editable
     * (bit 3), and not bitmap-only (bit 9).
     */
    public static boolean allowsDocumentEmbedding(int fsType) {
        boolean editable = (fsType & 0x000F) == 0 || (fsType & 0x0008) != 0;
        return editable && (fsType & 0x0200) == 0;
    }

    /**
     * The best string for each name ID of interest (1, 2, 6, 16, 17): Windows Unicode English first,
     * then any Windows Unicode or Unicode-platform string, then Macintosh Roman.
     */
    static Map<Integer, String> names(ByteBuffer file, int table) {
        int count = u16(file, table + 2);
        int strings = table + u16(file, table + 4);
        Map<Integer, String> best = new HashMap<>();
        Map<Integer, Integer> rank = new HashMap<>();
        for (int i = 0; i < count; i++) {
            int record = table + 6 + 12 * i;
            int platform = u16(file, record);
            int encoding = u16(file, record + 2);
            int language = u16(file, record + 4);
            int id = u16(file, record + 6);
            int score = score(platform, encoding, language);
            if (!interesting(id) || score == 0 || score <= rank.getOrDefault(id, 0)) {
                continue;
            }
            byte[] raw = new byte[u16(file, record + 8)];
            file.get(strings + u16(file, record + 10), raw);
            best.put(id, new String(raw, platform == 1 ? MAC_ROMAN : StandardCharsets.UTF_16BE).trim());
            rank.put(id, score);
        }
        return best;
    }

    static boolean interesting(int nameId) {
        return nameId == 1 || nameId == 2 || nameId == 6 || nameId == 16 || nameId == 17;
    }

    /** 3: Windows Unicode, US English; 2: other Windows Unicode, or the Unicode platform; 1: Mac Roman; 0: unreadable. */
    static int score(int platform, int encoding, int language) {
        if (platform == 3 && (encoding == 1 || encoding == 10)) {
            return language == 0x0409 ? 3 : 2;
        }
        if (platform == 0) {
            return 2;
        }
        return platform == 1 && encoding == 0 ? 1 : 0;
    }

    /** How a face is named in a message: its PostScript name, else family and style. */
    static String label(FontFace face) {
        return face.getPostscriptName().isEmpty() ? (face.getFamily() + " " + face.getStyle()).trim()
                : face.getPostscriptName();
    }

    /** At most 256 characters, the proto's cap. */
    static String clip(String value) {
        return value.length() > 256 ? value.substring(0, 256) : value;
    }

    static int u16(ByteBuffer file, int at) {
        return Short.toUnsignedInt(file.getShort(at));
    }

    static long u32(ByteBuffer file, int at) {
        return Integer.toUnsignedLong(file.getInt(at));
    }

    /** A 32-bit offset as an index; one past the int range reads as out of bounds. */
    static int offset(ByteBuffer file, int at) {
        long value = u32(file, at);
        if (value > Integer.MAX_VALUE) {
            throw new IndexOutOfBoundsException(Long.toString(value));
        }
        return (int) value;
    }
}
