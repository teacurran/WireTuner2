package com.villagecompute.wiretuner.api.blob;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.ByteBuffer;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;

/** The rechunker behind Download and the digest behind Upload. */
class BlobPartsTest {

    @Test
    void rechunkingSplitsIntoFullFramesAndAShortLastOne() {
        BlobGrpcService.Rechunker rechunker = new BlobGrpcService.Rechunker(4);
        assertThat(rechunker.add(ByteBuffer.wrap(new byte[] {1, 2, 3}))).isEmpty();
        assertThat(rechunker.add(ByteBuffer.wrap(new byte[] {4, 5, 6, 7, 8, 9, 10})))
                .containsExactly(ByteString.copyFrom(new byte[] {1, 2, 3, 4}), ByteString.copyFrom(new byte[] {5, 6, 7, 8}));
        assertThat(rechunker.flush()).containsExactly(ByteString.copyFrom(new byte[] {9, 10}));

        BlobGrpcService.Rechunker exact = new BlobGrpcService.Rechunker(2);
        assertThat(exact.add(ByteBuffer.wrap(new byte[] {1, 2}))).hasSize(1);
        assertThat(exact.flush()).isEmpty();
    }

    @Test
    void anUnknownDigestIsAnIllegalState() {
        assertThatThrownBy(() -> Upload.digest("NO-SUCH-DIGEST")).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("NO-SUCH-DIGEST");
    }

    @Test
    void keysFanOutByTheFirstByte() {
        assertThat(BlobStore.key("ab" + "0".repeat(62))).isEqualTo("blobs/ab/ab" + "0".repeat(62));
    }
}
