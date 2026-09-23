package com.villagecompute.wiretuner.api.sync;

import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;

import com.villagecompute.wiretuner.api.grpc.CallerContext;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.core.buffer.Buffer;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.RedisConnection;
import io.vertx.mutiny.redis.client.Request;
import io.vertx.mutiny.redis.client.Response;

import org.jboss.logging.Logger;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The fan-out bus of docs/spec/server.adoc (Ingest path): every frame about a document --
 * accepted changes, presence updates, document events -- is published on Valkey channel
 * {@code doc:<id>}; every node with a subscription on the document subscribes to the channel and
 * hands the frames to its local listeners. The publishing node delivers to its own listeners at
 * once, without waiting for Valkey, and drops its own frames when Valkey echoes them back.
 *
 * <p>One dedicated Valkey connection per node carries every channel subscription (the Quarkus
 * data source would open a connection per subscription). A channel is subscribed when its first
 * local listener arrives and unsubscribed when its last one leaves; a listener is registered only
 * once Valkey has confirmed the subscription, so nothing published afterwards is missed. When the
 * connection drops, the bus reconnects, resubscribes every channel and asks every listener to
 * resynchronise from the log, since frames published meanwhile are gone.
 *
 * <p>The payload is the publishing node's 16-byte id, the 16-byte audience (the account the frame is
 * for, all zeros for everyone), and the encoded {@code ServerFrame}.
 */
@ApplicationScoped
public class SyncBus {

    private static final Logger LOG = Logger.getLogger(SyncBus.class);

    static final String PREFIX = "doc:";
    static final String MESSAGE = "message";
    static final String SUBSCRIBE = "subscribe";

    /** A local consumer of one document's frames. */
    public interface Listener {
        /** A frame published about the document, for everyone or for this listener's account. */
        void frame(ServerFrame frame);

        /** The account whose frames this listener takes besides the ones for everyone; null for none. */
        UUID account();

        /** Frames may have been lost (the Valkey connection dropped): reread the log. */
        void resync();
    }

    /** One subscribed channel: its local listeners and the confirmation of its Valkey subscription. */
    static final class Channel {
        final Set<Listener> listeners = ConcurrentHashMap.newKeySet();
        final CompletableFuture<Void> ready = new CompletableFuture<>();
    }

    @Inject
    Redis redis;

    /** The audience of a frame for everyone, on the wire. */
    static final UUID EVERYONE = new UUID(0, 0);
    /** Node id and audience, 16 bytes each, before the frame. */
    static final int HEADER = 32;

    final byte[] node = uuidBytes(UUID.randomUUID());

    private final Map<UUID, Channel> channels = new ConcurrentHashMap<>();

    private Uni<RedisConnection> connection;

    /** Delivers the frame to this node's listeners, then publishes it for every other node. */
    public Uni<Void> publish(UUID documentId, ServerFrame frame) {
        return publish(documentId, frame, null);
    }

    /**
     * As {@link #publish(UUID, ServerFrame)}, for the subscriptions of one account only ({@code audience};
     * null = everyone): a {@code RoleChanged} or {@code AccessRemoved} is about the one person.
     */
    public Uni<Void> publish(UUID documentId, ServerFrame frame, UUID audience) {
        deliver(documentId, frame, audience);
        byte[] body = frame.toByteArray();
        byte[] payload = Arrays.copyOf(node, HEADER + body.length);
        System.arraycopy(uuidBytes(audience == null ? EVERYONE : audience), 0, payload, node.length, 16);
        System.arraycopy(body, 0, payload, HEADER, body.length);
        return redis.send(Request.cmd(Command.PUBLISH).arg(PREFIX + documentId).arg(Buffer.buffer(payload)))
                .replaceWithVoid();
    }

    /** The documents this node holds a channel for: the ones with a subscription here. */
    public Set<UUID> documents() {
        return channels.keySet();
    }

    /** Registers the listener; completes once Valkey has confirmed the document's channel. */
    public Uni<Listener> listen(UUID documentId, Listener listener) {
        Channel channel;
        synchronized (this) {
            channel = channels.get(documentId);
            if (channel == null) {
                channel = new Channel();
                channels.put(documentId, channel);
                command(Command.SUBSCRIBE, documentId);
            }
            channel.listeners.add(listener);
        }
        return Uni.createFrom().completionStage(channel.ready).emitOn(CallerContext.executor()).replaceWith(listener);
    }

    /** Removes the listener; the last one out unsubscribes the channel. */
    public void unlisten(UUID documentId, Listener listener) {
        synchronized (this) {
            Channel channel = channels.get(documentId);
            if (channel != null && channel.listeners.remove(listener) && channel.listeners.isEmpty()) {
                channels.remove(documentId);
                command(Command.UNSUBSCRIBE, documentId);
            }
        }
    }

    /** How many documents this node holds a channel for (tests, metrics). */
    int channelCount() {
        return channels.size();
    }

    /** Sends a (un)subscribe on the dedicated connection, in call order. */
    private void command(Command command, UUID documentId) {
        connection().chain(c -> c.send(Request.cmd(command).arg(PREFIX + documentId)))
                .subscribe().with(ignored -> { }, failure -> LOG.warnf(failure, "%s %s failed", command, documentId));
    }

    private synchronized Uni<RedisConnection> connection() {
        if (connection == null) {
            connection = redis.connect()
                    .invoke(c -> c.handler(this::onResponse).endHandler(this::onEnd))
                    .memoize().indefinitely();
        }
        return connection;
    }

    private void onResponse(Response response) {
        String kind = response.get(0).toString();
        route(kind, response.get(1).toString(), MESSAGE.equals(kind) ? response.get(2).toBytes() : null);
    }

    /** One push from Valkey: a message on a channel, or the confirmation of a subscription. */
    void route(String kind, String channelName, byte[] payload) {
        UUID documentId = UUID.fromString(channelName.substring(PREFIX.length()));
        Channel channel = channels.get(documentId);
        if (channel == null) {
            return;
        }
        if (SUBSCRIBE.equals(kind)) {
            channel.ready.complete(null);
        } else if (MESSAGE.equals(kind) && !Arrays.equals(node, 0, node.length, payload, 0, node.length)) {
            ByteBuffer header = ByteBuffer.wrap(payload, node.length, 16);
            UUID audience = new UUID(header.getLong(), header.getLong());
            ServerFrame frame = Protos.parse(ServerFrame.parser(), Arrays.copyOfRange(payload, HEADER, payload.length));
            deliver(channel, frame, EVERYONE.equals(audience) ? null : audience);
        }
    }

    /** The connection closed: reconnect, resubscribe every channel, and have every listener reread the log. */
    void onEnd() {
        LOG.warn("the Valkey pub/sub connection closed; reconnecting");
        synchronized (this) {
            connection = null;
            channels.keySet().forEach(documentId -> command(Command.SUBSCRIBE, documentId));
        }
        channels.values().forEach(channel -> channel.listeners.forEach(Listener::resync));
    }

    private void deliver(UUID documentId, ServerFrame frame, UUID audience) {
        Channel channel = channels.get(documentId);
        if (channel != null) {
            deliver(channel, frame, audience);
        }
    }

    private static void deliver(Channel channel, ServerFrame frame, UUID audience) {
        channel.listeners.forEach(listener -> {
            if (audience == null || audience.equals(listener.account())) {
                listener.frame(frame);
            }
        });
    }

    static byte[] uuidBytes(UUID id) {
        return ByteBuffer.allocate(16).putLong(id.getMostSignificantBits()).putLong(id.getLeastSignificantBits()).array();
    }
}
