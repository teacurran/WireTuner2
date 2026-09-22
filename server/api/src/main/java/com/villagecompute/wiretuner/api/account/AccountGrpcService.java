package com.villagecompute.wiretuner.api.account;

import com.villagecompute.wiretuner.account.v1.MutinyAccountServiceGrpc;

import io.quarkus.grpc.GrpcService;

/**
 * {@code wiretuner.account.v1.AccountService} (docs/spec/server.adoc, Services). Every RPC
 * inherits the generated default and answers UNIMPLEMENTED until SEC-002 implements the account
 * surface; the class exists now so the gRPC server, and with it {@code grpc.health.v1}, starts.
 */
@GrpcService
public class AccountGrpcService extends MutinyAccountServiceGrpc.AccountServiceImplBase {
}
