package com.villagecompute.wiretuner.api.account;

import java.time.Instant;
import java.util.List;

import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.account.v1.Account;
import com.villagecompute.wiretuner.account.v1.AccountIdentity;
import com.villagecompute.wiretuner.account.v1.Device;

/** Rows to {@code wiretuner.account.v1} messages. */
final class AccountMessages {

    private AccountMessages() {
    }

    static Account account(com.villagecompute.wiretuner.api.persistence.Account row,
            List<com.villagecompute.wiretuner.api.persistence.AccountIdentity> linked) {
        Account.Builder account = Account.newBuilder()
                .setId(row.id.toString())
                .setEmail(row.email)
                .setDisplayName(row.displayName)
                .setCreatedAt(timestamp(row.createdAt));
        for (var identity : linked) {
            account.addIdentities(identity(identity));
        }
        return account.build();
    }

    static AccountIdentity identity(com.villagecompute.wiretuner.api.persistence.AccountIdentity row) {
        return AccountIdentity.newBuilder()
                .setProvider(row.id.provider())
                .setEmail(row.email)
                .setEmailVerified(row.emailVerified)
                .setIsRelay(row.relay)
                .setLinkedAt(timestamp(row.linkedAt))
                .build();
    }

    static Device device(com.villagecompute.wiretuner.api.persistence.Device row, boolean current) {
        Device.Builder device = Device.newBuilder()
                .setId(row.id.deviceId().toString())
                .setName(row.name)
                .setPlatform(row.platform)
                .setAuthMethod(row.authMethod)
                .setLastSeenAt(timestamp(row.lastSeenAt))
                .setCurrent(current);
        if (row.revokedAt != null) {
            device.setRevokedAt(timestamp(row.revokedAt));
        }
        return device.build();
    }

    static Timestamp timestamp(Instant instant) {
        return Timestamp.newBuilder().setSeconds(instant.getEpochSecond()).setNanos(instant.getNano()).build();
    }
}
