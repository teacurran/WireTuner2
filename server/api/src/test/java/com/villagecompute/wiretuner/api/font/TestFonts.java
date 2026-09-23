package com.villagecompute.wiretuner.api.font;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Font files written for the tests (TXT-002's server half): an sfnt table directory over the tables
 * given, which need only be well formed where {@link FontFiles} reads them ({@code name},
 * {@code OS/2}); {@code cmap} and the outline tables are placeholders. Collections relocate each
 * font's table offsets, which a {@code ttcf} measures from the start of the file.
 */
public final class TestFonts {

    /** One {@code name} record. */
    public record Name(int platform, int encoding, int language, int id, String value) {
    }

    private TestFonts() {
    }

    /** A Windows Unicode, US English name record. */
    public static Name win(int id, String value) {
        return new Name(3, 1, 0x0409, id, value);
    }

    /** A {@code name} table of these records. */
    public static byte[] name(Name... records) {
        ByteArrayOutputStream strings = new ByteArrayOutputStream();
        ByteBuffer head = ByteBuffer.allocate(6 + 12 * records.length);
        head.putShort((short) 0).putShort((short) records.length).putShort((short) (6 + 12 * records.length));
        for (Name record : records) {
            Charset charset = record.platform() == 1 ? Charset.forName("x-MacRoman") : StandardCharsets.UTF_16BE;
            byte[] bytes = record.value().getBytes(charset);
            head.putShort((short) record.platform()).putShort((short) record.encoding())
                    .putShort((short) record.language()).putShort((short) record.id())
                    .putShort((short) bytes.length).putShort((short) strings.size());
            strings.writeBytes(bytes);
        }
        ByteArrayOutputStream table = new ByteArrayOutputStream();
        table.writeBytes(head.array());
        table.writeBytes(strings.toByteArray());
        return table.toByteArray();
    }

    /** An {@code OS/2} table carrying {@code fsType}. */
    public static byte[] os2(int fsType) {
        return ByteBuffer.allocate(96).putShort(0, (short) 4).putShort(8, (short) fsType).array();
    }

    /** The tables of a TrueType font named {@code family} {@code style} with {@code fsType}. */
    public static Map<Integer, byte[]> tables(String family, String style, int fsType) {
        Map<Integer, byte[]> tables = new LinkedHashMap<>();
        tables.put(FontFiles.CMAP, new byte[4]);
        tables.put(FontFiles.GLYF, new byte[4]);
        tables.put(FontFiles.NAME, name(win(1, family), win(2, style), win(6, (family + "-" + style).replace(" ", ""))));
        tables.put(FontFiles.OS2, os2(fsType));
        return tables;
    }

    /** A TrueType font. */
    public static byte[] ttf(String family, String style, int fsType) {
        return sfnt(FontFiles.SFNT_1, tables(family, style, fsType));
    }

    /** A TrueType font of about {@code size} bytes (its glyf table padded). */
    public static byte[] ttf(String family, int size) {
        Map<Integer, byte[]> tables = tables(family, "Regular", 0);
        tables.put(FontFiles.GLYF, new byte[Math.max(4, size - 300)]);
        return sfnt(FontFiles.SFNT_1, tables);
    }

    /** A font file of one face: this version and these tables. */
    public static byte[] sfnt(int version, Map<Integer, byte[]> tables) {
        return sfnt(version, tables, 0);
    }

    /** A collection of these fonts, each given as its version and tables. */
    @SafeVarargs
    public static byte[] collection(Map.Entry<Integer, Map<Integer, byte[]>>... fonts) {
        int header = 12 + 4 * fonts.length;
        List<byte[]> bodies = new ArrayList<>();
        int at = header;
        ByteBuffer head = ByteBuffer.allocate(header).putInt(FontFiles.TTCF).putInt(0x00010000).putInt(fonts.length);
        for (Map.Entry<Integer, Map<Integer, byte[]>> font : fonts) {
            head.putInt(at);
            byte[] body = sfnt(font.getKey(), font.getValue(), at);
            bodies.add(body);
            at += body.length;
        }
        ByteArrayOutputStream file = new ByteArrayOutputStream();
        file.writeBytes(head.array());
        bodies.forEach(file::writeBytes);
        return file.toByteArray();
    }

    /** One font whose table offsets count from {@code base} (0 for a lone font). */
    static byte[] sfnt(int version, Map<Integer, byte[]> tables, int base) {
        int directory = 12 + 16 * tables.size();
        ByteBuffer head = ByteBuffer.allocate(directory).putInt(version).putShort((short) tables.size())
                .putShort((short) 0).putShort((short) 0).putShort((short) 0);
        ByteArrayOutputStream data = new ByteArrayOutputStream();
        for (Map.Entry<Integer, byte[]> table : tables.entrySet()) {
            head.putInt(table.getKey()).putInt(0).putInt(base + directory + data.size()).putInt(table.getValue().length);
            data.writeBytes(table.getValue());
            data.writeBytes(new byte[(4 - table.getValue().length % 4) % 4]);
        }
        ByteArrayOutputStream file = new ByteArrayOutputStream();
        file.writeBytes(head.array());
        file.writeBytes(data.toByteArray());
        return file.toByteArray();
    }
}
