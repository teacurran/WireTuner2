package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.Test;

class CallMetadataTest {

    @Test
    void deviceIdParsesOnlyUuids() {
        CallMetadata metadata = new CallMetadata();
        assertThat(metadata.deviceUuid()).isNull();
        metadata.deviceId("not-a-uuid");
        assertThat(metadata.deviceUuid()).isNull();
        UUID id = UUID.randomUUID();
        metadata.deviceId(id.toString());
        assertThat(metadata.deviceUuid()).isEqualTo(id);
        assertThat(metadata.deviceId()).isEqualTo(id.toString());
    }

    @Test
    void holdsTheRestOfTheCall() {
        CallMetadata metadata = new CallMetadata();
        metadata.requestId("r");
        metadata.clientVersion("macos/1.0/1");
        metadata.bearerPresent(true);
        assertThat(metadata.requestId()).isEqualTo("r");
        assertThat(metadata.clientVersion()).isEqualTo("macos/1.0/1");
        assertThat(metadata.bearerPresent()).isTrue();
        metadata.authorization("Bearer x");
        assertThat(metadata.authorization()).isEqualTo("Bearer x");
    }
}
