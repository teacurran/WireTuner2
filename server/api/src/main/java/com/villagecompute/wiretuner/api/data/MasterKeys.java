package com.villagecompute.wiretuner.api.data;

import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * The service master keys ({@code wt.data.master-key}, from {@code WT_DATA_MASTER_KEY}): comma-separated
 * {@code id:base64} 32-byte keys, the first wrapping new data keys and the rest kept to unwrap rows the
 * rotation job has not reached (data-merge.adoc, Secret store). A KMS-backed key would replace this
 * bean; {@code key_id} already names which key wrapped each row.
 */
@ApplicationScoped
public class MasterKeys {

    @ConfigProperty(name = "wt.data.master-key")
    Optional<String> config;

    Envelope envelope;

    @PostConstruct
    void start() {
        envelope = Envelope.parse(config.orElse(""));
    }

    public Envelope envelope() {
        return envelope;
    }
}
