package com.villagecompute.wiretuner.api.comments;

import java.util.List;

import io.quarkus.mailer.MailTemplate;
import io.quarkus.qute.CheckedTemplate;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * The mention digest mail (COLLAB-031): one Qute mail per account and document, sent through the
 * same mailer as invitations (Mailpit locally, the mock mailbox in tests).
 */
@ApplicationScoped
public class CommentMailer {

    /** One mention as the mail lists it: who wrote it, the thread's opening line, the thread's link. */
    public record Mention(String author, String quote, String link) {
    }

    @CheckedTemplate
    static class Templates {

        private Templates() {
        }

        static native MailTemplate.MailTemplateInstance digest(String documentName, List<Mention> mentions);
    }

    Uni<Void> digest(String email, String documentName, List<Mention> mentions) {
        return Templates.digest(documentName, mentions)
                .to(email)
                .subject("You were mentioned in \"" + documentName + "\" on WireTuner")
                .send();
    }
}
