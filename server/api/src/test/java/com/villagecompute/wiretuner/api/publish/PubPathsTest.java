package com.villagecompute.wiretuner.api.publish;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.Test;

/** The pub origin's path rules: bundle paths, the trailing-slash redirect, and every refused trick. */
class PubPathsTest {

    static final UUID DOC = UUID.randomUUID();

    static PubPaths.Parsed parse(String rest) {
        return PubPaths.parse("/d/" + DOC + rest);
    }

    @Test
    void bundlePathsAreDecodedAndTheRootIsTheIndex() {
        assertThat(parse("/")).isEqualTo(new PubPaths.Parsed(200, DOC, "index.html"));
        assertThat(parse("/pages/page%201.svg")).isEqualTo(new PubPaths.Parsed(200, DOC, "pages/page 1.svg"));
        assertThat(parse("/images/caf%C3%A9.png").path()).isEqualTo("images/café.png");
        assertThat(parse("/.well-known")).isEqualTo(new PubPaths.Parsed(200, DOC, ".well-known"));
        assertThat(parse("")).isEqualTo(new PubPaths.Parsed(301, DOC, null));
    }

    @Test
    void otherPathsAreNotFound() {
        assertThat(PubPaths.parse("/").status()).isEqualTo(404);
        assertThat(PubPaths.parse("/d/not-a-uuid").status()).isEqualTo(404);
        assertThat(PubPaths.parse("/d/not-a-uuid/index.html").status()).isEqualTo(404);
    }

    @Test
    void traversalAndEncodingTricksAreBadRequests() {
        for (String bad : new String[] {"/../x", "/a/../b", "/./a", "/%2e%2e/x", "/a//b", "/a/", "/a%2fb", "/a%5cb",
                "/a\\b", "/a%00", "/a%01", "/a%7f", "/%", "/%4", "/%zz", "/%4z", "/%ff"}) {
            assertThat(parse(bad).status()).as(bad).isEqualTo(400);
        }
    }

    @Test
    void segmentsDecodeStrictly() {
        assertThat(PubPaths.decode("a%20b")).isEqualTo("a b");
        assertThat(PubPaths.decode("%C3")).isNull();
        assertThat(PubPaths.decode("é")).isEqualTo("é");
    }
}
