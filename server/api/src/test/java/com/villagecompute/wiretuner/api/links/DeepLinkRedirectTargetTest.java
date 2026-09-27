package com.villagecompute.wiretuner.api.links;

import static org.assertj.core.api.Assertions.assertThat;

import java.lang.reflect.Field;
import java.util.Arrays;

import org.junit.jupiter.api.Test;

/** COLLAB-038: the redirect's rewrite on its own, without the application. */
class DeepLinkRedirectTargetTest {

    static final String DOC = DeepLinkRedirectTest.DOC;

    @Test
    void theRewriteIsPure() {
        assertThat(DeepLinkRedirect.target(DOC, null, null)).contains("wiretuner://doc/" + DOC);
        assertThat(DeepLinkRedirect.target(DOC.toUpperCase(), "n", "1-2")).contains("wiretuner://doc/" + DOC + "/node/1-2");
        assertThat(DeepLinkRedirect.target(DOC, "n", null)).isEmpty();
        assertThat(DeepLinkRedirect.target("1-2-3-4-5", null, null)).isEmpty();
        assertThat(DeepLinkRedirect.target(DOC, "t", "7-3")).contains("wiretuner://doc/" + DOC + "/thread/7-3");
        assertThat(DeepLinkRedirect.target(DOC, "x", "1-2")).isEmpty();
        assertThat(DeepLinkRedirect.target(DOC, "n", "a-b")).isEmpty();
        assertThat(DeepLinkRedirect.target(DOC, "n", "18446744073709551616-1")).isEmpty();
        assertThat(DeepLinkRedirect.target("not-a-uuid", null, null)).isEmpty();
        // No database, no services: the resource holds nothing but its rewrite.
        Field[] fields = DeepLinkRedirect.class.getDeclaredFields();
        assertThat(Arrays.stream(fields).map(Field::getName)).containsExactly("ID");
    }
}
