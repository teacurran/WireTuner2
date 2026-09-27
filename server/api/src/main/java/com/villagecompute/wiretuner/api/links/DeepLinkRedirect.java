package com.villagecompute.wiretuner.api.links;

import java.net.URI;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Pattern;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.core.Response;

/**
 * The web form of a deep link (COLLAB-038; inspect.adoc, Data model): {@code GET /d/<document>},
 * {@code /d/<document>/n/<counter>-<replica>} and {@code /d/<document>/t/<counter>-<replica>} answer
 * 302 to {@code wiretuner://doc/<document>}, {@code .../node/<id>} and {@code .../thread/<id>}, for mail
 * clients and chat apps that refuse custom schemes. No lookup: the link is rewritten, never checked
 * (the app asks {@code DocumentService.Get} when it opens it), so the redirect touches no database and
 * needs no sign-in. A document that is not a UUID, or an id that is not two unsigned decimals, is 404.
 * Answers carry {@code Cache-Control: no-store} and {@code Referrer-Policy: no-referrer}.
 */
@Path("/d")
public class DeepLinkRedirect {

    static final Pattern ID = Pattern.compile("[0-9]{1,20}-[0-9]{1,20}");

    @GET
    @Path("{document}")
    public Response document(@PathParam("document") String document) {
        return answer(target(document, null, null));
    }

    @GET
    @Path("{document}/{kind}/{id}")
    public Response node(@PathParam("document") String document, @PathParam("kind") String kind, @PathParam("id") String id) {
        return answer(target(document, kind, id));
    }

    private static Response answer(Optional<String> target) {
        return target.map(location -> Response.status(Response.Status.FOUND).location(URI.create(location)))
                .orElseGet(() -> Response.status(Response.Status.NOT_FOUND))
                .header("Cache-Control", "no-store")
                .header("Referrer-Policy", "no-referrer")
                .build();
    }

    /**
     * The {@code wiretuner://} URL of a web link's parts ({@code kind} and {@code id} null for a document
     * link); empty when they are not a link.
     */
    static Optional<String> target(String document, String kind, String id) {
        UUID parsed;
        try {
            parsed = UUID.fromString(document);
        } catch (IllegalArgumentException e) {
            return Optional.empty();
        }
        if (!parsed.toString().equalsIgnoreCase(document)) {
            return Optional.empty();
        }
        String base = "wiretuner://doc/" + parsed;
        if (kind == null) {
            return Optional.of(base);
        }
        if (id == null || !ID.matcher(id).matches() || !unsigned(id)) {
            return Optional.empty();
        }
        return switch (kind) {
            case "n" -> Optional.of(base + "/node/" + id);
            case "t" -> Optional.of(base + "/thread/" + id);
            default -> Optional.empty();
        };
    }

    /** Both halves fit an unsigned 64-bit counter or replica. */
    private static boolean unsigned(String id) {
        for (String half : id.split("-")) {
            try {
                Long.parseUnsignedLong(half);
            } catch (NumberFormatException e) {
                return false;
            }
        }
        return true;
    }
}
