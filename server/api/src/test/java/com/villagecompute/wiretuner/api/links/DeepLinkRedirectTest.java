package com.villagecompute.wiretuner.api.links;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;

import io.quarkus.test.junit.QuarkusTest;

import org.junit.jupiter.api.Test;

/**
 * COLLAB-038: the web form of a deep link answers 302 to the {@code wiretuner://} URL without a
 * sign-in or any lookup.
 */
@QuarkusTest
class DeepLinkRedirectTest {

    static final String DOC = "0190f3a2-4b7c-7d8e-9f01-23456789abcd";

    @Test
    void aNodeLinkRedirectsToTheAppsScheme() {
        given().redirects().follow(false).when().get("/d/" + DOC + "/n/42-18446744073709551615")
                .then().statusCode(302)
                .header("Location", is("wiretuner://doc/" + DOC + "/node/42-18446744073709551615"))
                .header("Cache-Control", is("no-store"))
                .header("Referrer-Policy", is("no-referrer"));
    }

    @Test
    void threadAndDocumentLinksRedirectToo() {
        given().redirects().follow(false).when().get("/d/" + DOC + "/t/7-3")
                .then().statusCode(302).header("Location", is("wiretuner://doc/" + DOC + "/thread/7-3"));
        given().redirects().follow(false).when().get("/d/" + DOC)
                .then().statusCode(302).header("Location", is("wiretuner://doc/" + DOC));
    }

    @Test
    void anythingElseIsNotFound() {
        for (String path : new String[] {"/d/not-a-uuid", "/d/" + DOC + "/x/1-2", "/d/" + DOC + "/n/1", "/d/" + DOC + "/n/a-b",
                "/d/" + DOC + "/n/18446744073709551616-1", "/d/" + DOC.toUpperCase().replace('-', '0')}) {
            given().redirects().follow(false).when().get(path).then().statusCode(404);
        }
    }
}
