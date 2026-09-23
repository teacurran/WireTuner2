package com.villagecompute.wiretuner.api.team;

import java.time.Instant;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import io.quarkus.mailer.MailTemplate;
import io.quarkus.qute.CheckedTemplate;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * The team invitation mail (SEC-001): a Qute template sent through {@code quarkus-mailer}, Mailpit
 * locally and the mock mailbox in tests. The mail is the only place the token ever appears; the
 * link opens the app's accept-invite flow (SEC-003).
 */
@ApplicationScoped
public class InviteMailer {

    @ConfigProperty(name = "wt.links.base-url")
    String baseUrl;

    @CheckedTemplate
    static class Templates {

        private Templates() {
        }

        static native MailTemplate.MailTemplateInstance invite(String teamName, String inviterName, String role,
                String link, Instant expiresAt);
    }

    /** The accept link for a token. */
    String link(String token) {
        return baseUrl + "/invite/" + token;
    }

    Uni<Void> send(String email, String teamName, String inviterName, String role, String token, Instant expiresAt) {
        return Templates.invite(teamName, inviterName, role, link(token), expiresAt)
                .to(email)
                .subject(inviterName + " invited you to " + teamName + " on WireTuner")
                .send();
    }
}
