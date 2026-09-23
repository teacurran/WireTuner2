package com.villagecompute.wiretuner.api.share;

import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import io.quarkus.mailer.MailTemplate;
import io.quarkus.qute.CheckedTemplate;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Sharing mail (SRV-010): Qute templates sent through {@code quarkus-mailer} (Mailpit locally, the
 * mock mailbox in tests). Each links to the document itself ({@code <wt.links.base-url>/d/<id>}): a
 * document invitation carries no token, because the invitee's access is bound to their verified
 * address when they sign in.
 */
@ApplicationScoped
public class ShareMailer {

    @ConfigProperty(name = "wt.links.base-url")
    String baseUrl;

    @CheckedTemplate
    static class Templates {

        private Templates() {
        }

        static native MailTemplate.MailTemplateInstance invite(String documentName, String inviterName, String role,
                String link, String note);

        static native MailTemplate.MailTemplateInstance accessRequest(String documentName, String requesterName,
                String requesterEmail, String note, String link);

        static native MailTemplate.MailTemplateInstance accessResolved(String documentName, String role, String link);
    }

    /** The link that opens the document in the app. */
    String link(UUID documentId) {
        return baseUrl + "/d/" + documentId;
    }

    Uni<Void> invite(String email, String documentName, String inviterName, String role, UUID documentId, String note) {
        return Templates.invite(documentName, inviterName, role, link(documentId), note)
                .to(email)
                .subject(inviterName + " shared \"" + documentName + "\" with you on WireTuner")
                .send();
    }

    Uni<Void> accessRequest(String ownerEmail, String documentName, String requesterName, String requesterEmail,
            String note, UUID documentId) {
        return Templates.accessRequest(documentName, requesterName, requesterEmail, note, link(documentId))
                .to(ownerEmail)
                .subject(requesterName + " asks for access to \"" + documentName + "\"")
                .send();
    }

    /** Tells the requester the outcome; {@code role} is empty when the request was declined. */
    Uni<Void> accessResolved(String email, String documentName, String role, UUID documentId) {
        return Templates.accessResolved(documentName, role, link(documentId))
                .to(email)
                .subject("Your request for \"" + documentName + "\"")
                .send();
    }
}
