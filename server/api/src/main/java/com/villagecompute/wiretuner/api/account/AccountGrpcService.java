package com.villagecompute.wiretuner.api.account;

import java.util.List;
import java.util.Map;

import com.villagecompute.wiretuner.account.v1.GetPreferencesRequest;
import com.villagecompute.wiretuner.account.v1.GetPreferencesResponse;
import com.villagecompute.wiretuner.account.v1.MeRequest;
import com.villagecompute.wiretuner.account.v1.MeResponse;
import com.villagecompute.wiretuner.account.v1.MutinyAccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.SetPreferencesRequest;
import com.villagecompute.wiretuner.account.v1.SetPreferencesResponse;
import com.villagecompute.wiretuner.account.v1.StorageUsage;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.blob.StorageQuota;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.AccountIdentity;
import com.villagecompute.wiretuner.api.persistence.AccountIdentityRepository;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.Device;
import com.villagecompute.wiretuner.api.persistence.DeviceId;
import com.villagecompute.wiretuner.api.persistence.DeviceRepository;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.account.v1.AccountService} (docs/spec/server.adoc, Services). {@code Me} is the
 * authenticated RPC SRV-002 wires end to end: resolving the principal creates the account and
 * device rows on first sight, and the response reads them back, with the blob storage use and limit
 * of every space the caller can upload into (IO-008). {@code GetPreferences} and
 * {@code SetPreferences} keep the synced preferences (COLLAB-031 reads {@code sync.email_mentions}
 * from them). The remaining RPCs inherit the generated default and answer UNIMPLEMENTED until the
 * account surface is implemented.
 */
@GrpcService
public class AccountGrpcService extends MutinyAccountServiceGrpc.AccountServiceImplBase {

    @Inject
    RoleGuard guard;

    @Inject
    AccountRepository accounts;

    @Inject
    AccountIdentityRepository identities;

    @Inject
    DeviceRepository devices;

    @Inject
    StorageQuota quota;

    static final String READ = "SELECT preferences::text FROM account WHERE id = $1";
    static final String LOCK = READ + " FOR UPDATE";
    static final String WRITE = "UPDATE account SET preferences = cast(cast($2 AS text) AS jsonb) WHERE id = $1";

    @Inject
    Pool pool;

    @Override
    public Uni<GetPreferencesResponse> getPreferences(GetPreferencesRequest request) {
        return Panache.withTransaction(() -> guard.authenticated())
                .chain(principal -> pool.preparedQuery(READ).execute(Tuple.of(principal.accountId())))
                .chain(rows -> Preferences.parse(rows.iterator().next().getString(0)))
                .map(preferences -> GetPreferencesResponse.newBuilder().setPreferences(preferences).build());
    }

    /** Merges the changes per key (newest {@code updated_at_ms} wins) and answers the whole map. */
    @Override
    public Uni<SetPreferencesResponse> setPreferences(SetPreferencesRequest request) {
        return Panache.withTransaction(() -> guard.authenticated())
                .chain(principal -> pool.withTransaction(connection -> connection.preparedQuery(LOCK)
                        .execute(Tuple.of(principal.accountId()))
                        .chain(rows -> Preferences.parse(rows.iterator().next().getString(0)))
                        .map(stored -> Preferences.merge(stored, request.getChanges()))
                        .chain(merged -> Preferences.json(merged).chain(json -> {
                            if (json.length() > Preferences.CAP_BYTES) {
                                return Uni.createFrom().failure(StatusExceptions.validationFailed(
                                        "the preferences would exceed " + Preferences.CAP_BYTES + " bytes",
                                        Map.of("changes", "the merged map exceeds " + Preferences.CAP_BYTES + " bytes")));
                            }
                            return connection.preparedQuery(WRITE).execute(Tuple.of(principal.accountId(), json))
                                    .replaceWith(merged);
                        }))))
                .map(merged -> SetPreferencesResponse.newBuilder().setPreferences(merged).build());
    }

    @Override
    public Uni<MeResponse> me(MeRequest request) {
        return Panache.withTransaction(() -> guard.authenticated().flatMap(this::describe));
    }

    private Uni<MeResponse> describe(Principal principal) {
        return accounts.findById(principal.accountId())
                .flatMap(account -> identities.listForAccount(account.id)
                        .flatMap(linked -> currentDevice(principal).map(device -> response(account, linked, device))))
                .flatMap(response -> quota.of(principal.accountId()).map(usage -> response.toBuilder()
                        .addAllStorage(usage.stream().map(u -> StorageUsage.newBuilder().setSpaceId(u.spaceId().toString())
                                .setUsedBytes(u.usedBytes()).setLimitBytes(u.limitBytes()).build()).toList())
                        .build()));
    }

    private Uni<Device> currentDevice(Principal principal) {
        if (principal.deviceId() == null) {
            return Uni.createFrom().nullItem();
        }
        return devices.findById(new DeviceId(principal.accountId(), principal.deviceId()));
    }

    private static MeResponse response(Account account, List<AccountIdentity> linked, Device device) {
        MeResponse.Builder response = MeResponse.newBuilder().setAccount(AccountMessages.account(account, linked));
        if (device != null) {
            response.setDevice(AccountMessages.device(device, true));
        }
        return response.build();
    }
}
