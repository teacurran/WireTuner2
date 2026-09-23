package com.villagecompute.wiretuner.api.data;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.HexFormat;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.data.v1.FetchRequest;

import io.vertx.core.json.DecodeException;
import io.vertx.core.json.JsonObject;

/**
 * The resumable position of a Fetch (data-merge.adoc, Pagination engine and extraction): where the
 * next page is -- a next URL, or a page number -- and how many pages and records the fetch has
 * streamed, bound to the request it came from by a fingerprint of the request (without its cursor,
 * serialized deterministically) and signed with HMAC-SHA256 under a key derived from the current
 * master key. A cursor that was altered, or that belongs to another document, source, parameter set
 * or path list, is {@code INVALID_ARGUMENT / VALIDATION_FAILED}. Rotating the master key invalidates
 * outstanding cursors: the client starts the fetch again.
 *
 * @param nextUrl the next page's URL (NEXT_URL mode), or empty
 * @param page the next page number (PAGE_PARAM mode), or 0
 * @param pages pages streamed so far
 * @param records records streamed so far
 */
public record FetchCursor(String nextUrl, long page, int pages, long records) {

    static final String PURPOSE = "wt-fetch-cursor";

    /** The signed token for this position of {@code request}. */
    public String sign(FetchRequest request, byte[] key) {
        byte[] payload = new JsonObject().put("f", fingerprint(request)).put("u", nextUrl).put("p", page).put("n", pages)
                .put("r", records).encode().getBytes(StandardCharsets.UTF_8);
        Base64.Encoder b64 = Base64.getUrlEncoder().withoutPadding();
        return b64.encodeToString(payload) + "." + b64.encodeToString(mac(key, payload));
    }

    /** The position a token holds, when it is authentic and belongs to {@code request}. */
    public static FetchCursor verify(String token, FetchRequest request, byte[] key) {
        int dot = token.indexOf('.');
        if (dot < 0) {
            throw Cursors.invalid();
        }
        byte[] payload;
        byte[] signature;
        try {
            payload = Base64.getUrlDecoder().decode(token.substring(0, dot));
            signature = Base64.getUrlDecoder().decode(token.substring(dot + 1));
        } catch (IllegalArgumentException e) {
            throw Cursors.invalid();
        }
        if (!MessageDigest.isEqual(mac(key, payload), signature)) {
            throw Cursors.invalid();
        }
        JsonObject o;
        try {
            o = new JsonObject(new String(payload, StandardCharsets.UTF_8));
        } catch (DecodeException e) {
            throw Cursors.invalid();
        }
        if (!fingerprint(request).equals(o.getString("f"))) {
            throw Cursors.invalid();
        }
        return new FetchCursor(o.getString("u"), o.getLong("p"), o.getInteger("n"), o.getLong("r"));
    }

    /** sha256 of the request without its cursor: the rest of the message, then its parameters in key order. */
    static String fingerprint(FetchRequest request) {
        byte[] message = request.toBuilder().clearCursor().clearParams().build().toByteArray();
        byte[] params = new java.util.TreeMap<>(request.getParamsMap()).toString().getBytes(StandardCharsets.UTF_8);
        return HexFormat.of().formatHex(Envelope.crypto("fingerprint", () -> {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update(message);
            return digest.digest(params);
        }));
    }

    static byte[] mac(byte[] key, byte[] payload) {
        return Envelope.crypto("cursor signature", () -> {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(payload);
        });
    }
}
