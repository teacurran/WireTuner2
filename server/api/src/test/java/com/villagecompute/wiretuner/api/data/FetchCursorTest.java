package com.villagecompute.wiretuner.api.data;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.doc.v1.HttpSource;

import io.grpc.StatusRuntimeException;

/** DATA-009: resumable cursors are signed and bound to their request; anything else is refused. */
class FetchCursorTest {

    static final byte[] KEY = "cursor-key-for-tests".getBytes(StandardCharsets.UTF_8);

    static FetchRequest request(String url) {
        return FetchRequest.newBuilder().setDocumentId("0190a2f2-0000-7000-8000-000000000001")
                .setSource(HttpSource.newBuilder().setUrl(url)).putParams("b", "2").putParams("a", "1").addPaths("$.id").build();
    }

    static void refused(String token, FetchRequest request) {
        try {
            FetchCursor.verify(token, request, KEY);
        } catch (StatusRuntimeException e) {
            assertThat(StatusExceptions.reasonOf(e)).contains(ErrorReasons.VALIDATION_FAILED);
            return;
        }
        throw new AssertionError("accepted " + token);
    }

    @Test
    void roundTripsForTheSameRequest() {
        FetchRequest request = request("https://a.example/x");
        FetchCursor cursor = new FetchCursor("https://a.example/x?page=2", 0, 3, 120);
        String token = cursor.sign(request, KEY);
        assertThat(FetchCursor.verify(token, request, KEY)).isEqualTo(cursor);
        // Parameter order and the cursor field itself do not change the binding.
        FetchRequest reordered = FetchRequest.newBuilder(request).clearParams().putParams("a", "1").putParams("b", "2")
                .setCursor(token).build();
        assertThat(FetchCursor.verify(token, reordered, KEY)).isEqualTo(cursor);
    }

    @Test
    void refusesTamperedForeignAndMalformedCursors() {
        FetchRequest request = request("https://a.example/x");
        String token = new FetchCursor("", 4, 3, 30).sign(request, KEY);
        String payload = token.substring(0, token.indexOf('.'));
        String signature = token.substring(token.indexOf('.') + 1);
        String forged = Base64.getUrlEncoder().withoutPadding().encodeToString(
                new String(Base64.getUrlDecoder().decode(payload), StandardCharsets.UTF_8).replace("\"p\":4", "\"p\":1")
                        .getBytes(StandardCharsets.UTF_8));
        refused(forged + "." + signature, request);
        refused(token, request("https://b.example/x"));
        refused(token, FetchRequest.newBuilder(request).putParams("a", "other").build());
        refused(new FetchCursor("", 4, 3, 30).sign(request, "another key".getBytes(StandardCharsets.UTF_8)), request);
        refused("nodot", request);
        refused("!!!.???", request);
        byte[] notJson = "not json".getBytes(StandardCharsets.UTF_8);
        refused(Base64.getUrlEncoder().withoutPadding().encodeToString(notJson) + "."
                + Base64.getUrlEncoder().withoutPadding().encodeToString(FetchCursor.mac(KEY, notJson)), request);
    }
}
