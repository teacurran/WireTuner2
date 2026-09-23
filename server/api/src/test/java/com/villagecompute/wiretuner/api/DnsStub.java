package com.villagecompute.wiretuner.api;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;

/**
 * A tiny authoritative DNS server on 127.0.0.1 answering TXT queries from {@link #TXT}, so workspace
 * domain verification (SEC-001) runs against a real resolver round trip without the network. Unknown
 * names are NXDOMAIN; other record types get an empty answer.
 */
public class DnsStub implements QuarkusTestResourceLifecycleManager {

    /** Domain (lower-case) to its TXT strings; tests publish and withdraw records here. */
    public static final Map<String, List<String>> TXT = new ConcurrentHashMap<>();

    static final int TYPE_TXT = 16;

    private DatagramSocket socket;
    private Thread server;

    @Override
    public Map<String, String> start() {
        try {
            socket = new DatagramSocket(0, InetAddress.getLoopbackAddress());
        } catch (SocketException e) {
            throw new IllegalStateException(e);
        }
        server = Thread.ofPlatform().daemon().name("dns-stub").start(this::serve);
        return Map.of("wt.dns.host", "127.0.0.1", "wt.dns.port", Integer.toString(socket.getLocalPort()),
                "wt.dns.timeout-ms", "2000");
    }

    @Override
    public void stop() {
        socket.close();
    }

    private void serve() {
        byte[] buffer = new byte[512];
        while (!socket.isClosed()) {
            DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
            try {
                socket.receive(packet);
                byte[] reply = answer(buffer, packet.getLength());
                socket.send(new DatagramPacket(reply, reply.length, packet.getSocketAddress()));
            } catch (IOException e) {
                // socket closed at shutdown
            }
        }
    }

    static byte[] answer(byte[] query, int length) {
        int at = 12;
        StringBuilder name = new StringBuilder();
        while (query[at] != 0) {
            int label = query[at] & 0xff;
            if (!name.isEmpty()) {
                name.append('.');
            }
            name.append(new String(query, at + 1, label, StandardCharsets.US_ASCII));
            at += label + 1;
        }
        int questionEnd = at + 5;
        int type = ((query[at + 1] & 0xff) << 8) | (query[at + 2] & 0xff);
        List<String> records = TXT.get(name.toString().toLowerCase(Locale.ROOT));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(query[0]);
        out.write(query[1]);
        out.write(0x81);
        out.write(records == null ? 0x83 : 0x80);
        List<String> answers = records != null && type == TYPE_TXT ? records : List.of();
        out.writeBytes(new byte[] {0, 1, 0, (byte) answers.size(), 0, 0, 0, 0});
        out.write(query, 12, questionEnd - 12);
        for (String record : answers) {
            byte[] text = record.getBytes(StandardCharsets.US_ASCII);
            out.writeBytes(new byte[] {(byte) 0xc0, 0x0c, 0, TYPE_TXT, 0, 1, 0, 0, 0, 60, 0, (byte) (text.length + 1),
                    (byte) text.length});
            out.writeBytes(text);
        }
        return out.toByteArray();
    }
}
