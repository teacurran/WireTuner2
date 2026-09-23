package com.villagecompute.wiretuner.api.blob;

import java.nio.ByteBuffer;
import java.time.Instant;
import java.util.HexFormat;
import java.util.UUID;

import com.google.protobuf.ByteString;
import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Blob;
import com.villagecompute.wiretuner.api.persistence.BlobRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentBlobId;
import com.villagecompute.wiretuner.api.persistence.DocumentBlobRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.blob.v1.BlobInfo;
import com.villagecompute.wiretuner.blob.v1.BlobTag;
import com.villagecompute.wiretuner.blob.v1.DownloadRequest;
import com.villagecompute.wiretuner.blob.v1.DownloadResponse;
import com.villagecompute.wiretuner.blob.v1.MutinyBlobServiceGrpc;
import com.villagecompute.wiretuner.blob.v1.StatRequest;
import com.villagecompute.wiretuner.blob.v1.StatResponse;
import com.villagecompute.wiretuner.blob.v1.UploadHeader;
import com.villagecompute.wiretuner.blob.v1.UploadRequest;
import com.villagecompute.wiretuner.blob.v1.UploadResponse;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.blob.v1.BlobService} (SRV-008; docs/spec/sync-protocol.adoc, Blobs). Blobs are
 * content-addressed and visible only through a document: an upload needs the editor role on the
 * document it names and records the hash against it (or, tagged {@code THUMBNAIL}, makes it the
 * document's thumbnail); Stat and Download need any role and a document that references the hash.
 *
 * <p>Upload streams to object storage without holding the blob in memory: chunks are hashed as
 * they arrive and buffered into 8 MiB multipart parts; the multipart upload is completed only when
 * the size and sha256 match the header, and aborted otherwise, so a bad upload never becomes
 * visible. A blob the server already holds is still hashed end to end (a hash alone must not grant
 * access to content) but not stored again.
 */
@GrpcService
public class BlobGrpcService extends MutinyBlobServiceGrpc.BlobServiceImplBase {

    static final String TAG_CONTENT = "content";
    static final String TAG_THUMBNAIL = "thumbnail";
    static final String DEFAULT_MEDIA_TYPE = "application/octet-stream";
    /** Download frames are at most this long (the proto's 1 MiB cap). */
    static final int DOWNLOAD_CHUNK = 1024 * 1024;

    @Inject
    RoleGuard guard;

    @Inject
    BlobStore store;

    @Inject
    BlobRepository blobs;

    @Inject
    DocumentBlobRepository documentBlobs;

    @Inject
    DocumentRepository documents;

    @Override
    public Uni<StatResponse> stat(StatRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        String sha = hex(request.getSha256());
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER)
                .chain(() -> visibleBlob(documentId, sha)))
                .map(blob -> blob == null ? StatResponse.newBuilder().setExists(false).build()
                        : StatResponse.newBuilder().setExists(true).setBlob(info(blob)).build());
    }

    @Override
    public Multi<DownloadResponse> download(DownloadRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        String sha = hex(request.getSha256());
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER)
                .chain(() -> visibleBlob(documentId, sha))
                .onItem().ifNull().failWith(StatusExceptions::blobNotFound))
                .onItem().transformToMulti(blob -> {
                    Rechunker rechunker = new Rechunker(DOWNLOAD_CHUNK);
                    Multi<DownloadResponse> chunks = store.get(blob.storageKey)
                            .onItem().transformToIterable(rechunker::add)
                            .onCompletion().switchTo(() -> Multi.createFrom().iterable(rechunker.flush()))
                            .map(chunk -> DownloadResponse.newBuilder().setChunk(chunk).build());
                    return Multi.createBy().concatenating()
                            .streams(Multi.createFrom().item(DownloadResponse.newBuilder().setInfo(info(blob)).build()), chunks);
                });
    }

    /** The blob, when the server holds it and the document references it or shows it as its thumbnail; else null. */
    private Uni<Blob> visibleBlob(UUID documentId, String sha) {
        return blobs.findById(sha).chain(blob -> blob == null ? Uni.createFrom().<Blob>nullItem()
                : documentBlobs.findById(new DocumentBlobId(documentId, sha)).chain(reference -> reference != null
                        ? Uni.createFrom().item(blob)
                        : documents.findById(documentId).map(doc -> sha.equals(doc.thumbnailBlob) ? blob : null)));
    }

    @Override
    public Uni<UploadResponse> upload(Multi<UploadRequest> frames) {
        Upload upload = new Upload(store);
        return frames.onItem().transformToUniAndConcatenate(frame -> accept(upload, frame))
                .collect().last()
                .chain(upload::finish)
                .chain(() -> Panache.withTransaction(() -> record(upload)))
                .onFailure().call(upload::abort)
                .map(blob -> UploadResponse.newBuilder().setBlob(info(blob)).build());
    }

    private Uni<Void> accept(Upload upload, UploadRequest frame) {
        if (upload.header != null) {
            return upload.chunk(frame);
        }
        if (!frame.hasHeader()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("the first frame of an upload must be its header"));
        }
        UploadHeader header = frame.getHeader();
        UUID documentId = UUID.fromString(header.getDocumentId());
        return Panache.withTransaction(() -> guard.require(documentId, Role.EDITOR)
                .chain(() -> blobs.findById(hex(header.getSha256()))))
                .invoke(existing -> upload.begin(header, documentId, existing != null))
                .replaceWithVoid();
    }

    /** Records the blob row (first upload wins), then the document's reference or its thumbnail. */
    private Uni<Blob> record(Upload upload) {
        String sha = upload.sha256Hex();
        String tag = upload.header.getTag() == BlobTag.BLOB_TAG_THUMBNAIL ? TAG_THUMBNAIL : TAG_CONTENT;
        Uni<Blob> row = blobs.insertIfAbsent(sha, upload.header.getSize(), upload.header.getMediaType(),
                BlobStore.key(sha), tag);
        if (TAG_THUMBNAIL.equals(tag)) {
            return row.call(() -> documents.findById(upload.documentId).invoke(doc -> {
                doc.thumbnailBlob = sha;
                doc.thumbnailAt = Instant.now();
            }));
        }
        return row.call(() -> documentBlobs.reference(upload.documentId, sha));
    }

    static BlobInfo info(Blob blob) {
        return BlobInfo.newBuilder()
                .setSha256(ByteString.copyFrom(HexFormat.of().parseHex(blob.sha256)))
                .setSize(blob.sizeBytes)
                .setMediaType(blob.mediaType)
                .setTag(TAG_THUMBNAIL.equals(blob.tag) ? BlobTag.BLOB_TAG_THUMBNAIL : BlobTag.BLOB_TAG_UNSPECIFIED)
                .setCreatedAt(Timestamp.newBuilder()
                        .setSeconds(blob.createdAt.getEpochSecond())
                        .setNanos(blob.createdAt.getNano()))
                .build();
    }

    static String hex(ByteString sha256) {
        return HexFormat.of().formatHex(sha256.toByteArray());
    }

    /** Splits the storage client's buffers into frames of at most {@code max} bytes. */
    static final class Rechunker {
        private final int max;
        private ByteString pending = ByteString.EMPTY;

        Rechunker(int max) {
            this.max = max;
        }

        /** Takes the next buffer; returns every full frame it completes. */
        java.util.List<ByteString> add(ByteBuffer buffer) {
            pending = pending.concat(ByteString.copyFrom(buffer));
            java.util.List<ByteString> full = new java.util.ArrayList<>();
            while (pending.size() >= max) {
                full.add(pending.substring(0, max));
                pending = pending.substring(max);
            }
            return full;
        }

        /** The last, short frame, if any bytes are left. */
        java.util.List<ByteString> flush() {
            return pending.isEmpty() ? java.util.List.of() : java.util.List.of(pending);
        }
    }
}
