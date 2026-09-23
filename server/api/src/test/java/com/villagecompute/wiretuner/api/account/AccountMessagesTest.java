package com.villagecompute.wiretuner.api.account;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.persistence.Device;
import com.villagecompute.wiretuner.api.persistence.DeviceId;

/** Row mapping the Me path cannot reach: a revoked device (Me refuses it; ListDevices will list it). */
class AccountMessagesTest {

    @Test
    void aRevokedDeviceCarriesItsRevocation() {
        Device row = new Device();
        row.id = new DeviceId(UUID.randomUUID(), UUID.randomUUID());
        row.revokedAt = Instant.ofEpochSecond(1_700_000_000L, 5);
        var device = AccountMessages.device(row, false);
        assertThat(device.getRevokedAt().getSeconds()).isEqualTo(1_700_000_000L);
        assertThat(device.getRevokedAt().getNanos()).isEqualTo(5);
        assertThat(device.getCurrent()).isFalse();
        assertThat(device.getAuthMethod()).isEqualTo("password");
    }
}
