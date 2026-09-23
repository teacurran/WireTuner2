package com.villagecompute.wiretuner.api.blob;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.security.MessageDigest;
import java.time.Duration;
import java.util.List;
import java.util.Random;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.blob.v1.BlobInfo;
import com.villagecompute.wiretuner.blob.v1.BlobTag;
import com.villagecompute.wiretuner.blob.v1.DownloadRequest;
import com.villagecompute.wiretuner.blob.v1.DownloadResponse;
import com.villagecompute.wiretuner.blob.v1.MutinyBlobServiceGrpc;
import com.villagecompute.wiretuner.blob.v1.StatRequest;
import com.villagecompute.wiretuner.blob.v1.StatResponse;
import com.villagecompute.wiretuner.blob.v1.UploadHeader;
import com.villagecompute.wiretuner.blob.v1.UploadRequest;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.GetRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;
import io.smallrye.mutiny.Multi;

/**
 * SRV-008: BlobService against MinIO (Testcontainers): streamed upload with sha256 verification,
 * multipart for large blobs, deduplication, thumbnails, Stat and Download through a referencing
 * document, per role.
 */
@QuarkusTest
class BlobServiceTest extends ServiceTestSupport {

    static final Duration WAIT = Duration.ofMinutes(5);
    static final int MIB = 1024 * 1024;

    @GrpcClient("blob")
    MutinyBlobServiceGrpc.MutinyBlobServiceStub blobs;

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    UUID alice;
    UUID bob;
    UUID carol;
    UUID doc;

    @BeforeEach
    void setUp() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        carol = TestUsers.accountId(account, CAROL);
        TestUsers.accountId(account, DAVE);
        doc = document(ALICE);
        share(doc, bob, "editor");
        share(doc, carol, "viewer");
    }

    UUID document(String user) {
        UUID id = uuid7();
        UUID space = TestUsers.accountId(account, user);
        as(docs, user).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(space.toString())
                .setName("Blobs").build());
        return id;
    }

    /** Deterministic pseudo-random content, generated chunk by chunk so large blobs never sit in memory. */
    record Content(long seed, long size) {

        byte[] chunk(long index, int chunkSize) {
            int length = (int) Math.min(chunkSize, size - index * chunkSize);
            byte[] bytes = new byte[length];
            new Random(seed * 31 + index).nextBytes(bytes);
            return bytes;
        }

        long chunks(int chunkSize) {
            return (size + chunkSize - 1) / chunkSize;
        }

        ByteString sha256() {
            MessageDigest digest = Upload.digest("SHA-256");
            for (long i = 0; i < chunks(MIB); i++) {
                digest.update(chunk(i, MIB));
            }
            return ByteString.copyFrom(digest.digest());
        }

        byte[] all() {
            byte[] bytes = new byte[(int) size];
            for (long i = 0; i < chunks(MIB); i++) {
                byte[] chunk = chunk(i, MIB);
                System.arraycopy(chunk, 0, bytes, (int) (i * MIB), chunk.length);
            }
            return bytes;
        }
    }

    static Content content(long size) {
        return new Content(new Random().nextLong(), size);
    }

    UploadHeader header(UUID document, ByteString sha, long size, BlobTag tag) {
        return UploadHeader.newBuilder().setDocumentId(document.toString()).setSha256(sha).setSize(size)
                .setMediaType("application/x-test").setTag(tag).build();
    }

    Multi<UploadRequest> frames(UploadHeader header, Content content) {
        Multi<UploadRequest> chunks = Multi.createFrom().range(0, (int) content.chunks(MIB))
                .map(i -> UploadRequest.newBuilder().setChunk(ByteString.copyFrom(content.chunk(i, MIB))).build());
        return Multi.createBy().concatenating()
                .streams(Multi.createFrom().item(UploadRequest.newBuilder().setHeader(header).build()), chunks);
    }

    BlobInfo upload(String user, UploadHeader header, Content content) {
        return as(blobs, user).upload(frames(header, content)).await().atMost(WAIT).getBlob();
    }

    BlobInfo upload(String user, Content content) {
        return upload(user, header(doc, content.sha256(), content.size(), BlobTag.BLOB_TAG_UNSPECIFIED), content);
    }

    StatResponse stat(String user, UUID document, ByteString sha) {
        return as(blobs, user).stat(StatRequest.newBuilder().setDocumentId(document.toString()).setSha256(sha).build())
                .await().atMost(WAIT);
    }

    List<DownloadResponse> download(String user, UUID document, ByteString sha) {
        return as(blobs, user).download(DownloadRequest.newBuilder().setDocumentId(document.toString()).setSha256(sha)
                .build()).collect().asList().await().atMost(WAIT);
    }

    static byte[] joined(List<DownloadResponse> frames) {
        ByteString all = ByteString.EMPTY;
        for (DownloadResponse frame : frames.subList(1, frames.size())) {
            assertThat(frame.hasChunk()).isTrue();
            assertThat(frame.getChunk().size()).isLessThanOrEqualTo(MIB);
            all = all.concat(frame.getChunk());
        }
        return all.toByteArray();
    }

    // ---------------------------------------------------------------------------------- Upload

    @Test
    void aSmallBlobUploadsStatsAndDownloads() {
        Content content = content(300_000);
        BlobInfo info = upload(BOB, content);
        assertThat(info.getSha256()).isEqualTo(content.sha256());
        assertThat(info.getSize()).isEqualTo(300_000);
        assertThat(info.getMediaType()).isEqualTo("application/x-test");
        assertThat(info.getTag()).isEqualTo(BlobTag.BLOB_TAG_UNSPECIFIED);

        StatResponse stat = stat(CAROL, doc, content.sha256());
        assertThat(stat.getExists()).isTrue();
        assertThat(stat.getBlob()).isEqualTo(info);

        List<DownloadResponse> frames = download(CAROL, doc, content.sha256());
        assertThat(frames.get(0).getInfo()).isEqualTo(info);
        assertThat(joined(frames)).isEqualTo(content.all());
    }

    @Test
    void aLargeBlobGoesThroughMultipartAndDownloadsInFrames() {
        Content content = content(9L * MIB + 12_345);
        BlobInfo info = upload(ALICE, content);
        assertThat(info.getSize()).isEqualTo(content.size());
        List<DownloadResponse> frames = download(ALICE, doc, content.sha256());
        assertThat(frames).hasSizeGreaterThan(2);
        assertThat(joined(frames)).isEqualTo(content.all());
    }

    @Test
    void a200MibUploadSucceedsAndIsDeduplicatedOnReUpload() {
        Content content = content(200L * MIB);
        ByteString sha = content.sha256();
        BlobInfo first = upload(ALICE, header(doc, sha, content.size(), BlobTag.BLOB_TAG_UNSPECIFIED), content);
        assertThat(first.getSize()).isEqualTo(200L * MIB);

        // Another document, the same content: hashed again, stored once, referenced twice.
        UUID other = document(BOB);
        BlobInfo second = upload(BOB, header(other, sha, content.size(), BlobTag.BLOB_TAG_UNSPECIFIED), content);
        assertThat(second).isEqualTo(first);
        String hex = BlobGrpcService.hex(sha);
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 = ?", hex)).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM document_blob WHERE sha256 = ?", hex)).isEqualTo(2);
        assertThat(stat(BOB, other, sha).getExists()).isTrue();
    }

    @Test
    void contentThatDisagreesWithTheHeaderIsRejectedAndNeverStored() {
        Content content = content(1000);
        Content other = content(1000);
        assertFails(() -> upload(ALICE, header(doc, other.sha256(), 1000, BlobTag.BLOB_TAG_UNSPECIFIED), content),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertFails(() -> upload(ALICE, header(doc, content.sha256(), 2000, BlobTag.BLOB_TAG_UNSPECIFIED), content),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertFails(() -> upload(ALICE, header(doc, content.sha256(), 500, BlobTag.BLOB_TAG_UNSPECIFIED), content),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertThat(stat(ALICE, doc, content.sha256()).getExists()).isFalse();

        // Past the first multipart part: the started upload is aborted.
        Content large = content(9L * MIB);
        assertFails(() -> upload(ALICE, header(doc, other.sha256(), large.size(), BlobTag.BLOB_TAG_UNSPECIFIED), large),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 = ?", BlobGrpcService.hex(other.sha256()))).isZero();
    }

    @Test
    void knowingAHashIsNotEnoughToClaimTheBlob() {
        Content secret = content(4096);
        upload(ALICE, secret);
        UUID mine = document(DAVE);
        Content junk = content(4096);
        assertFails(() -> upload(DAVE, header(mine, secret.sha256(), 4096, BlobTag.BLOB_TAG_UNSPECIFIED), junk),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertThat(stat(DAVE, mine, secret.sha256()).getExists()).isFalse();
        assertFails(() -> download(DAVE, mine, secret.sha256()), Status.Code.NOT_FOUND, "BLOB_NOT_FOUND");
    }

    @Test
    void framesOutOfOrderAreRejected() {
        Content content = content(10);
        UploadHeader header = header(doc, content.sha256(), 10, BlobTag.BLOB_TAG_UNSPECIFIED);
        UploadRequest chunk = UploadRequest.newBuilder().setChunk(ByteString.copyFrom(content.all())).build();
        UploadRequest head = UploadRequest.newBuilder().setHeader(header).build();

        assertFails(() -> as(blobs, ALICE).upload(Multi.createFrom().items(chunk, head)).await().atMost(WAIT),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertFails(() -> as(blobs, ALICE).upload(Multi.createFrom().items(head, head, chunk)).await().atMost(WAIT),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
        assertFails(() -> as(blobs, ALICE).upload(Multi.createFrom().empty()).await().atMost(WAIT),
                Status.Code.INVALID_ARGUMENT, "BLOB_MISMATCH");
    }

    @Test
    void uploadNeedsAnEditorAndReadingAnyRole() {
        Content content = content(64);
        assertFails(() -> upload(CAROL, content), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> upload(DAVE, content), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");
        upload(BOB, content);
        assertFails(() -> stat(DAVE, doc, content.sha256()), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");
        assertFails(() -> download(DAVE, doc, content.sha256()), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");
        assertThat(download(CAROL, doc, content.sha256())).hasSize(2);
    }

    @Test
    void statSaysNoForAHashTheDocumentDoesNotReference() {
        Content content = content(128);
        assertThat(stat(ALICE, doc, content.sha256()).getExists()).isFalse();
        assertThat(stat(ALICE, doc, content.sha256()).hasBlob()).isFalse();
        UUID elsewhere = document(ALICE);
        upload(ALICE, header(elsewhere, content.sha256(), 128, BlobTag.BLOB_TAG_UNSPECIFIED), content);
        assertThat(stat(ALICE, doc, content.sha256()).getExists()).isFalse();
        assertFails(() -> download(ALICE, doc, content.sha256()), Status.Code.NOT_FOUND, "BLOB_NOT_FOUND");
        assertFails(() -> download(ALICE, doc, content(3).sha256()), Status.Code.NOT_FOUND, "BLOB_NOT_FOUND");
    }

    // ------------------------------------------------------------------------------ Thumbnails

    @Test
    void aThumbnailUploadBecomesTheDocumentsThumbnailWithoutAReference() {
        Content png = content(40_000);
        UploadHeader header = header(doc, png.sha256(), png.size(), BlobTag.BLOB_TAG_THUMBNAIL).toBuilder()
                .setMediaType("").build();
        BlobInfo info = upload(BOB, header, png);
        assertThat(info.getTag()).isEqualTo(BlobTag.BLOB_TAG_THUMBNAIL);
        assertThat(info.getMediaType()).isEmpty();

        var shown = as(docs, CAROL).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build()).getDocument();
        assertThat(shown.getThumbnailBlob()).isEqualTo(png.sha256());
        assertThat(shown.hasThumbnailAt()).isTrue();
        assertThat(count("SELECT count(*) FROM document_blob WHERE document_id = ?", doc)).isZero();
        assertThat(stat(CAROL, doc, png.sha256()).getExists()).isTrue();
        assertThat(joined(download(CAROL, doc, png.sha256()))).isEqualTo(png.all());

        // Newest wins.
        Content newer = content(1000);
        upload(BOB, header(doc, newer.sha256(), newer.size(), BlobTag.BLOB_TAG_THUMBNAIL), newer);
        assertThat(as(docs, CAROL).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build()).getDocument()
                .getThumbnailBlob()).isEqualTo(newer.sha256());
        assertThat(stat(CAROL, doc, png.sha256()).getExists()).isFalse();
    }

    @Test
    void aTaggedUploadIsCappedAt256Kib() {
        Content big = content(300_000);
        assertFails(() -> upload(BOB, header(doc, big.sha256(), big.size(), BlobTag.BLOB_TAG_THUMBNAIL), big),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    @Test
    void aMalformedHashIsValidationFailed() {
        StatRequest request = StatRequest.newBuilder().setDocumentId(doc.toString())
                .setSha256(ByteString.copyFrom(new byte[31])).build();
        assertFails(() -> as(blobs, ALICE).stat(request).await().atMost(WAIT),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }
}
