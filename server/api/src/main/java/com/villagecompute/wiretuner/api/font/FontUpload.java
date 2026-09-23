package com.villagecompute.wiretuner.api.font;

import java.io.ByteArrayOutputStream;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Map;
import java.util.UUID;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.account.v1.UploadFontHeader;
import com.villagecompute.wiretuner.account.v1.UploadFontRequest;
import com.villagecompute.wiretuner.api.blob.Upload;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.smallrye.mutiny.Uni;

/**
 * The state of one {@code FontLibraryService.UploadFont} stream: the header, the running sha256, and
 * the file, held in memory (at most 64 MiB, the header's cap) because the whole file is read before
 * anything is stored. Frames arrive one at a time (the service concatenates them).
 */
final class FontUpload {

    private final MessageDigest digest = Upload.digest("SHA-256");
    private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();

    UploadFontHeader header;
    UUID accountId;
    boolean alreadyStored;

    /** The header frame, once the caller's role and the team's quota have been checked. */
    void begin(UploadFontHeader header, UUID accountId, boolean alreadyStored) {
        this.header = header;
        this.accountId = accountId;
        this.alreadyStored = alreadyStored;
    }

    UUID teamId() {
        return UUID.fromString(header.getTeamId());
    }

    String sha256Hex() {
        return HexFormat.of().formatHex(header.getSha256().toByteArray());
    }

    byte[] bytes() {
        return buffer.toByteArray();
    }

    /** A frame after the header: hashed, counted and kept. */
    Uni<Void> chunk(UploadFontRequest frame) {
        if (frame.hasHeader()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("an upload carries exactly one header, first"));
        }
        ByteString bytes = frame.getChunk();
        if (buffer.size() + (long) bytes.size() > header.getSize()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch(
                    "the chunks exceed the header's size of " + header.getSize() + " bytes"));
        }
        digest.update(bytes.asReadOnlyByteBuffer());
        buffer.writeBytes(bytes.toByteArray());
        return Uni.createFrom().voidItem();
    }

    /** End of stream: size and hash must match the header, and the file must be a font the library accepts. */
    Uni<FontFiles.Font> finish() {
        if (header == null) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("an upload needs a header"));
        }
        if (buffer.size() != header.getSize()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch(
                    "received " + buffer.size() + " bytes; the header says " + header.getSize()));
        }
        if (!HexFormat.of().formatHex(digest.digest()).equals(sha256Hex())) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("the content's sha256 differs from the header's"));
        }
        try {
            return Uni.createFrom().item(FontFiles.read(bytes()));
        } catch (FontFiles.Rejected e) {
            return Uni.createFrom().failure(StatusExceptions.validationFailed(
                    "the file is not a font the team library accepts", Map.of("content", e.getMessage())));
        }
    }
}
