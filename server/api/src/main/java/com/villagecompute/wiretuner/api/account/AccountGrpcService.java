package com.villagecompute.wiretuner.api.account;

import java.util.List;

import com.villagecompute.wiretuner.account.v1.MeRequest;
import com.villagecompute.wiretuner.account.v1.MeResponse;
import com.villagecompute.wiretuner.account.v1.MutinyAccountServiceGrpc;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
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

import jakarta.inject.Inject;

/**
 * {@code wiretuner.account.v1.AccountService} (docs/spec/server.adoc, Services). {@code Me} is the
 * authenticated RPC SRV-002 wires end to end: resolving the principal creates the account and
 * device rows on first sight, and the response reads them back. The remaining RPCs inherit the
 * generated default and answer UNIMPLEMENTED until SEC-002/SEC-003 implement the account surface.
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

    @Override
    public Uni<MeResponse> me(MeRequest request) {
        return Panache.withTransaction(() -> guard.authenticated().flatMap(this::describe));
    }

    private Uni<MeResponse> describe(Principal principal) {
        return accounts.findById(principal.accountId())
                .flatMap(account -> identities.listForAccount(account.id)
                        .flatMap(linked -> currentDevice(principal).map(device -> response(account, linked, device))));
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
