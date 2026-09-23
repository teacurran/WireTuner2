package com.villagecompute.wiretuner.api.blob;

import java.io.ByteArrayOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.blob.v1.UploadHeader;
import com.villagecompute.wiretuner.blob.v1.UploadRequest;

import io.smallrye.mutiny.Uni;

import software.amazon.awssdk.services.s3.model.CompletedPart;

/**
 * The state of one {@code BlobService.Upload} stream: the header, the running sha256 and size, and
 * the multipart upload the chunks are buffered into. Frames arrive one at a time (the service
 * concatenates them), so no field needs synchronisation.
 */
final class Upload {

    /** Multipart part size: S3 needs at least 5 MiB for every part but the last. */
    static final int PART_SIZE = 8 * 1024 * 1024;

    private final BlobStore store;
    private final MessageDigest digest = digest("SHA-256");
    private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    private final List<CompletedPart> parts = new ArrayList<>();

    UploadHeader header;
    UUID documentId;
    private boolean alreadyStored;
    private long received;
    private String uploadId;
    private String key;

    Upload(BlobStore store) {
        this.store = store;
    }

    static MessageDigest digest(String algorithm) {
        try {
            return MessageDigest.getInstance(algorithm);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(algorithm + " is not available in this JDK", e);
        }
    }

    /** The header frame, once the caller's role has been checked. */
    void begin(UploadHeader header, UUID documentId, boolean alreadyStored) {
        this.header = header;
        this.documentId = documentId;
        this.alreadyStored = alreadyStored;
        this.key = BlobStore.key(sha256Hex());
    }

    String sha256Hex() {
        return BlobGrpcService.hex(header.getSha256());
    }

    /** A frame after the header: hashed, counted, and buffered unless the blob is already stored. */
    Uni<Void> chunk(UploadRequest frame) {
        if (frame.hasHeader()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("an upload carries exactly one header, first"));
        }
        ByteString bytes = frame.getChunk();
        received += bytes.size();
        if (received > header.getSize()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch(
                    "the chunks exceed the header's size of " + header.getSize() + " bytes"));
        }
        digest.update(bytes.asReadOnlyByteBuffer());
        if (alreadyStored) {
            return Uni.createFrom().voidItem();
        }
        buffer.writeBytes(bytes.toByteArray());
        return buffer.size() >= PART_SIZE ? flushPart() : Uni.createFrom().voidItem();
    }

    private Uni<Void> flushPart() {
        byte[] part = buffer.toByteArray();
        buffer.reset();
        Uni<String> started = uploadId != null ? Uni.createFrom().item(uploadId)
                : store.startMultipart(key, mediaType()).invoke(id -> uploadId = id);
        return started.chain(id -> store.uploadPart(key, id, parts.size() + 1, part))
                .invoke(parts::add)
                .replaceWithVoid();
    }

    /** End of stream: size and hash must match the header; then the object is made visible. */
    Uni<Void> finish() {
        if (header == null) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("an upload needs a header"));
        }
        if (received != header.getSize()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch(
                    "received " + received + " bytes; the header says " + header.getSize()));
        }
        if (!HexFormat.of().formatHex(digest.digest()).equals(sha256Hex())) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("the content's sha256 differs from the header's"));
        }
        if (alreadyStored) {
            return Uni.createFrom().voidItem();
        }
        if (uploadId == null) {
            return store.put(key, buffer.toByteArray(), mediaType());
        }
        Uni<Void> last = buffer.size() > 0 ? flushPart() : Uni.createFrom().voidItem();
        return last.chain(() -> store.completeMultipart(key, uploadId, parts));
    }

    /** After a failure: discards the unfinished multipart upload, if one was started. */
    Uni<Void> abort() {
        if (uploadId == null) {
            return Uni.createFrom().voidItem();
        }
        return store.abortMultipart(key, uploadId).onFailure().recoverWithNull();
    }

    private String mediaType() {
        return header.getMediaType().isEmpty() ? BlobGrpcService.DEFAULT_MEDIA_TYPE : header.getMediaType();
    }
}
