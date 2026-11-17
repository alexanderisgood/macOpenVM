// SPDX-License-Identifier: GPL-2.0-or-later
// Links QEMU's patched display server and real local socket event loop.
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "qemu/sockets.h"
#include "ui/mvo-shared-frame.h"
#include "ScanoutLeasePool.h"
#include "SharedFrameFixture.h"
#include "SharedFrameWire.h"
#include "SharedHDRFrameTransport.h"

typedef struct {
    MVOScanoutLeasePool pool;
    unsigned released;
    bool retired;
} Producer;

static bool take_latest(void *opaque, MVOSharedFrameLease *result)
{
    Producer *producer = opaque;
    MVOScanoutLease lease;
    if (!mvo_scanout_lease_take_latest(&producer->pool, &lease)) {
        return false;
    }
    *result = (MVOSharedFrameLease){lease.sequence, lease.slot};
    return true;
}

static void release(void *opaque, MVOSharedFrameLease lease)
{
    Producer *producer = opaque;
    g_assert_true(mvo_scanout_lease_release_read(
        &producer->pool, (MVOScanoutLease){producer->pool.epoch, lease.sequence, lease.slot}));
    producer->released++;
}

static void retire(void *opaque)
{
    Producer *producer = opaque;
    producer->retired = true;
    mvo_scanout_lease_retire(&producer->pool);
}

static void send_header(int peer, MVOSharedFrameHeader header, unsigned kind)
{
    uint8_t bytes[MVO_SF_BYTES];
    header.kind = kind;
    mvo_sf_encode(&header, bytes);
    g_assert_cmpint(send(peer, bytes, sizeof(bytes), 0), ==, sizeof(bytes));
    main_loop_wait(true);
}

static MVOSharedFrameHeader receive_header(int peer, unsigned kind, unsigned descriptors)
{
    MVOSharedFrameReceive rx;
    mvo_sf_receive_init(&rx);
    int result = 0;
    for (unsigned i = 0; i < 10 && result == 0; i++) {
        main_loop_wait(true);
        result = mvo_sf_receive(peer, &rx);
    }
    g_assert_cmpint(result, ==, 1);
    MVOSharedFrameHeader header;
    g_assert_true(mvo_sf_decode(rx.bytes, &header));
    g_assert_cmpuint(header.kind, ==, kind);
    g_assert_cmpuint(rx.descriptor_count, ==, descriptors);
    for (unsigned i = 0; i < descriptors; i++) {
        for (unsigned j = 0; j < i; j++) {
            g_assert_true(mvo_hdr_readonly_slots_distinct(
                rx.descriptors[i], rx.descriptors[j], header.mapped_bytes));
        }
    }
    mvo_sf_receive_clear(&rx);
    return header;
}

static MVOScanoutLease complete_frame(Producer *producer, MVOSharedFrameServer *server)
{
    MVOScanoutLease lease;
    g_assert_true(mvo_scanout_lease_begin_write(&producer->pool, &lease));
    g_assert_true(mvo_scanout_lease_finish_write(&producer->pool, lease, true));
    mvo_shared_frame_leases_ready(server, producer);
    return lease;
}

static int connect_peer(const char *path)
{
    int peer = socket(AF_UNIX, SOCK_STREAM, 0);
    g_assert_cmpint(peer, >=, 0);
    struct sockaddr_un addr = {.sun_len = sizeof(addr), .sun_family = AF_UNIX};
    g_assert_cmpuint(strlen(path), <, sizeof(addr.sun_path));
    g_strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    g_assert_cmpint(connect(peer, (struct sockaddr *)&addr, sizeof(addr)), ==, 0);
    return peer;
}

int main(int argc, char **argv)
{
    g_assert_cmpint(argc, ==, 2);
    qemu_init_main_loop(&error_abort);
    MVOSharedFrameServer *server = mvo_shared_frame_new(argv[1], &error_abort);
    g_assert_nonnull(server);
    int peer = connect_peer(argv[1]);
    MVOSharedFrameHeader ready = receive_header(peer, MVO_SF_READY, 0);
    MVOSharedFrameHeader request = {0};
    memcpy(request.epoch, ready.epoch, sizeof(request.epoch));

    Producer producer = {0};
    const MVOSharedFrameLeaseOps ops = {take_latest, release, retire};
    g_assert_true(mvo_scanout_lease_init(&producer.pool, 1));
    MVOFrameFixturePool pair, spare;
    size_t bytes = getpagesize();
    g_assert_cmpint(mvo_fixture_pool(&pair, bytes, true), ==, 0);
    g_assert_cmpint(mvo_fixture_pool(&spare, bytes, true), ==, 0);
    int slots[] = {pair.descriptors[0], pair.descriptors[1], spare.descriptors[0]};
    g_assert_true(mvo_shared_frame_attach_leases(
        server, &producer, 0, 64, getpagesize() / 256, 256, bytes, slots, &ops, &producer));
    mvo_fixture_clear(&pair);
    mvo_fixture_clear(&spare);

    send_header(peer, request, MVO_SF_REQUEST);
    MVOSharedFrameHeader attach = receive_header(peer, MVO_SF_ATTACH, 3);
    send_header(peer, attach, MVO_SF_ACK);
    MVOScanoutLease first = complete_frame(&producer, server);
    MVOSharedFrameHeader one = receive_header(peer, MVO_SF_FRAME, 0);
    g_assert_cmpuint(one.slot, ==, first.slot);
    send_header(peer, one, MVO_SF_ACK);
    g_assert_cmpuint(producer.released, ==, 0);
    g_assert_cmpint(producer.pool.slots[first.slot].state, ==, MVO_SCANOUT_BORROWED);

    send_header(peer, request, MVO_SF_REQUEST);
    MVOScanoutLease second = complete_frame(&producer, server);
    MVOSharedFrameHeader two = receive_header(peer, MVO_SF_FRAME, 0);
    g_assert_cmpuint(two.slot, ==, second.slot);
    g_assert_cmpuint(two.generation, ==, second.sequence);
    g_assert_cmpuint(one.slot, !=, two.slot);
    g_assert_cmpuint(producer.released, ==, 0);
    send_header(peer, two, MVO_SF_ACK);
    g_assert_cmpuint(producer.released, ==, 1);
    g_assert_cmpint(producer.pool.slots[first.slot].state, ==, MVO_SCANOUT_FREE);
    g_assert_cmpint(producer.pool.slots[second.slot].state, ==, MVO_SCANOUT_BORROWED);

    close(peer);
    main_loop_wait(true);
    g_assert_true(producer.retired);
    g_assert_cmpuint(producer.released, ==, 1);
    MVOScanoutLease forbidden;
    g_assert_false(mvo_scanout_lease_begin_write(&producer.pool, &forbidden));

    uint8_t pixels[64 * 64 * 4] = {0};
    mvo_shared_frame_update(server, pixels, 0, pixels, 64, 64, 256);
    peer = connect_peer(argv[1]);
    ready = receive_header(peer, MVO_SF_READY, 0);
    memcpy(request.epoch, ready.epoch, sizeof(request.epoch));
    send_header(peer, request, MVO_SF_REQUEST);
    attach = receive_header(peer, MVO_SF_ATTACH, 2);
    send_header(peer, attach, MVO_SF_ACK);
    one = receive_header(peer, MVO_SF_FRAME, 0);
    g_assert_cmpuint(one.slot, ==, 0);
    g_assert_cmpuint(one.sequence, ==, 1);
    send_header(peer, one, MVO_SF_ACK);
    close(peer);
    main_loop_wait(true);
    g_assert_cmpint(unlink(argv[1]), ==, 0);
    puts("QEMU scanout leases: descriptor delivery, exact ACK release, retirement and snapshot fallback passed");
    return 0;
}
