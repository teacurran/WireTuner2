package com.villagecompute.wiretuner.crdt;

import com.github.luben.zstd.ZstdException;

/**
 * zstd compression for snapshots (docs/spec/crdt-model.adoc, "Snapshots") through zstd-jni,
 * mirroring {@code WTCRDT.Zstd}; both write and read standard zstd frames.
 */
public final class Zstd {

    /** The level snapshots are compressed at (zstd's default). */
    public static final int LEVEL = 3;

    private Zstd() {
    }

    /** {@code data} as one zstd frame (with its content size). */
    public static byte[] compress(byte[] data) {
        return com.github.luben.zstd.Zstd.compress(data, LEVEL);
    }

    /**
     * Decompresses one zstd frame of exactly {@code size} bytes of content.
     *
     * @throws IllegalArgumentException when {@code data} is not such a frame
     */
    public static byte[] decompress(byte[] data, int size) {
        byte[] out = new byte[size];
        long written;
        try {
            written = com.github.luben.zstd.Zstd.decompressByteArray(out, 0, size, data, 0, data.length);
        } catch (ZstdException e) {
            throw new IllegalArgumentException("zstd: " + e.getMessage(), e);
        }
        if (written != size) {
            throw new IllegalArgumentException("zstd: " + written + " bytes of content, expected " + size);
        }
        return out;
    }
}
