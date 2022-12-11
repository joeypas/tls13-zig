const std = @import("std");
const log = @import("log.zig");
const key = @import("key.zig");
const PskIdentity = @import("pre_shared_key.zig").PskIdentity;

const client = @import("client.zig");

const Error = error{EarlyDataIsNotAccepted};

pub fn main() !void {
    try do(std.heap.page_allocator);
}

fn do(allocator: std.mem.Allocator) !void {
    log.info("started.", .{});
    var tls_client = try client.TLSClientTCP.init(allocator);
    defer tls_client.deinit();
    tls_client.print_keys = true;
    tls_client.allow_self_signed = true;
    try tls_client.connect("localhost", 8443);

    const http_req = "GET / HTTP/1.1\r\nHost: localhost\r\nUser-Agent: tls13-zig\r\nAccept: */*\r\n\r\n";
    _ = try tls_client.send(http_req);

    var recv_bytes: [4096]u8 = undefined;
    var recv_size = tls_client.recv(&recv_bytes) catch |err| blk: {
        log.err("faile to receive, err={}", .{err});
        break :blk 0;
    };

    log.info("RECV=\n {s}", .{recv_bytes[0..recv_size]});

    try tls_client.close();
    log.info("finished.", .{});

    var tls_client_res = try client.TLSClientTCP.init(allocator);
    defer tls_client_res.deinit();
    tls_client_res.print_keys = true;
    tls_client_res.allow_self_signed = true;
    tls_client_res.res_secret = tls_client.ks.secret.res_secret;
    tls_client_res.ks = try key.KeyScheduler.init(tls_client.ks.hkdf, tls_client.ks.aead);
    const nst = tls_client.session_ticket.?;
    tls_client_res.pre_shared_key = try PskIdentity.init(allocator, nst.ticket.len);
    std.mem.copy(u8, tls_client_res.pre_shared_key.?.identity, nst.ticket);
    tls_client_res.pre_shared_key.?.obfuscated_ticket_age = nst.ticket_age_add + 10; // TODO: measure time
    tls_client_res.early_data = http_req;

    try tls_client_res.connect("localhost", 8443);

    _ = try tls_client_res.send(http_req);

    try tls_client_res.close();

    if (!tls_client_res.resume_accepted or !tls_client_res.early_data_ok) {
        return Error.EarlyDataIsNotAccepted;
    }
    log.info("finished.", .{});

    return;
}

test "e2e with 0rtt" {
    try do(std.testing.allocator);
}
