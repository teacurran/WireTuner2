package com.villagecompute.wiretuner.api.data;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.Arrays;
import java.util.List;

/**
 * The address ranges the fetch proxy never connects to (data-merge.adoc, Fetch proxy and SSRF guard):
 * every address a host resolves to is checked, and one blocked address refuses the host.
 *
 * <p>IPv4: this network, RFC 1918, CGNAT, loopback, link-local (with the metadata address
 * 169.254.169.254), the IETF protocol, documentation, benchmarking and 6to4-relay blocks, multicast,
 * reserved and broadcast. IPv6: unspecified, loopback and the IPv4-compatible block, discard,
 * Teredo, ORCHID, documentation, unique-local (with the metadata address fd00:ec2::254), site- and
 * link-local, multicast, and the local-use NAT64 prefix. Addresses that embed an IPv4 address -- an
 * IPv4-mapped address, the well-known NAT64 prefix 64:ff9b::/96 and 6to4 2002::/16 -- are judged by the
 * IPv4 address they carry.
 */
public final class AddressPolicy {

    record Cidr(byte[] prefix, int bits) {

        boolean contains(byte[] address) {
            int full = bits / 8;
            if (!Arrays.equals(address, 0, full, prefix, 0, full)) {
                return false;
            }
            int rest = bits % 8;
            if (rest == 0) {
                return true;
            }
            int mask = (0xff << (8 - rest)) & 0xff;
            return (address[full] & mask) == (prefix[full] & mask);
        }
    }

    static final List<Cidr> BLOCKED_V4 = cidrs("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
            "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
            "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4");

    static final List<Cidr> BLOCKED_V6 = cidrs("::/96", "64:ff9b:1::/48", "100::/64", "2001::/32", "2001:10::/28",
            "2001:20::/28", "2001:db8::/32", "fc00::/7", "fec0::/10", "fe80::/10", "ff00::/8");

    private static final Cidr MAPPED = new Cidr(new byte[] {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, (byte) 0xff, (byte) 0xff, 0, 0, 0,
            0}, 96);
    private static final Cidr NAT64 = cidr("64:ff9b::/96");
    private static final Cidr SIX_TO_FOUR = cidr("2002::/16");

    private AddressPolicy() {
    }

    /** True when the fetch proxy must not connect to the address. */
    public static boolean blocked(InetAddress address) {
        return blocked(address.getAddress());
    }

    static boolean blocked(byte[] address) {
        if (address.length == 4) {
            return BLOCKED_V4.stream().anyMatch(c -> c.contains(address));
        }
        if (MAPPED.contains(address) || NAT64.contains(address)) {
            return blocked(Arrays.copyOfRange(address, 12, 16));
        }
        if (SIX_TO_FOUR.contains(address)) {
            return blocked(Arrays.copyOfRange(address, 2, 6));
        }
        return BLOCKED_V6.stream().anyMatch(c -> c.contains(address));
    }

    static List<Cidr> cidrs(String... ranges) {
        return Arrays.stream(ranges).map(AddressPolicy::cidr).toList();
    }

    static Cidr cidr(String range) {
        int slash = range.indexOf('/');
        return new Cidr(literal(range.substring(0, slash)), Integer.parseInt(range.substring(slash + 1)));
    }

    /** The bytes of an IP literal. */
    static byte[] literal(String address) {
        return address(address).getAddress();
    }

    /**
     * An IP literal as an address; callers pass literals only (constants, DNS answers, dotted quads and
     * bracketed IPv6 from URLs), so no lookup happens. A malformed literal is an {@link IllegalArgumentException}.
     */
    static InetAddress address(String literal) {
        try {
            return InetAddress.getByName(literal);
        } catch (UnknownHostException e) {
            throw new IllegalArgumentException("not an IP literal: " + literal, e);
        }
    }
}
