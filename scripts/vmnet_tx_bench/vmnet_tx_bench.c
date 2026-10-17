// SPDX-License-Identifier: Apache-2.0
// Host-only TX service-rate benchmark for libkrun's native vmnet bridge.
//
// Feeds guest-sized Ethernet frames into the production bridge code with no VM,
// so the host side of the guest-to-host path can be measured in isolation:
//
//   socket    socketpair -> production receive/copy path, no vmnet_write
//   bridge    socketpair -> bridge thread -> vmnet_write  (the runtime's TX path)
//   direct N  vmnet_write from the caller thread, N frames per call
//
// vmnet shared mode needs root. Build and run with scripts/vmnet_tx_bench/run.sh.
#include <errno.h>
#include <getopt.h>
#include <poll.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

#include KRUN_VMNET_SOURCE

#define FEEDER_SOCKET_BUF (7 * 1024 * 1024)

static const uint8_t GUEST_MAC[6] = {0xf2, 0x58, 0x08, 0xca, 0x0f, 0x46};
static const uint8_t GUEST_IP[4] = {192, 168, 200, 2};
static uint8_t GATEWAY_MAC[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t cpu_ns(void)
{
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    uint64_t user = (uint64_t)usage.ru_utime.tv_sec * 1000000000ull + (uint64_t)usage.ru_utime.tv_usec * 1000ull;
    uint64_t sys = (uint64_t)usage.ru_stime.tv_sec * 1000000000ull + (uint64_t)usage.ru_stime.tv_usec * 1000ull;
    return user + sys;
}

static uint32_t csum_add(uint32_t sum, const uint8_t *data, size_t length)
{
    for (size_t i = 0; i + 1 < length; i += 2) {
        sum += (uint32_t)(data[i] << 8 | data[i + 1]);
    }
    if (length & 1) {
        sum += (uint32_t)(data[length - 1] << 8);
    }
    return sum;
}

static uint16_t csum_fold(uint32_t sum)
{
    while (sum >> 16) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return (uint16_t)~sum;
}

// Ethernet + IPv4 + TCP segment from the guest to the gateway, shaped like a
// TSO frame from a guest with checksum offload: valid IP checksum, TCP checksum
// holding the pseudo-header partial sum, zero payload.
static void build_frame(uint8_t *frame, size_t length, const uint8_t gateway[4], uint32_t seq)
{
    memset(frame, 0, length);
    memcpy(frame, GATEWAY_MAC, 6);
    memcpy(frame + 6, GUEST_MAC, 6);
    frame[12] = 0x08;
    frame[13] = 0x00;

    uint8_t *ip = frame + 14;
    size_t ip_length = length - 14;
    ip[0] = 0x45;
    ip[2] = (uint8_t)(ip_length >> 8);
    ip[3] = (uint8_t)ip_length;
    ip[6] = 0x40; // don't fragment
    ip[8] = 64;
    ip[9] = 6; // TCP
    memcpy(ip + 12, GUEST_IP, 4);
    memcpy(ip + 16, gateway, 4);
    uint16_t ip_csum = csum_fold(csum_add(0, ip, 20));
    ip[10] = (uint8_t)(ip_csum >> 8);
    ip[11] = (uint8_t)ip_csum;

    uint8_t *tcp = ip + 20;
    size_t tcp_length = ip_length - 20;
    tcp[0] = 0x9c; tcp[1] = 0x40;   // source port 40000
    tcp[2] = 0x00; tcp[3] = 0x09;   // destination port 9 (discard)
    tcp[4] = (uint8_t)(seq >> 24); tcp[5] = (uint8_t)(seq >> 16);
    tcp[6] = (uint8_t)(seq >> 8); tcp[7] = (uint8_t)seq;
    tcp[12] = 0x50;                 // data offset 5
    tcp[13] = 0x18;                 // PSH|ACK
    tcp[14] = 0xff; tcp[15] = 0xff; // window
    uint8_t pseudo[12] = {0};
    memcpy(pseudo, GUEST_IP, 4);
    memcpy(pseudo + 4, gateway, 4);
    pseudo[9] = 6;
    pseudo[10] = (uint8_t)(tcp_length >> 8);
    pseudo[11] = (uint8_t)tcp_length;
    uint32_t partial = csum_add(0, pseudo, 12);
    while (partial >> 16) {
        partial = (partial & 0xffff) + (partial >> 16);
    }
    tcp[16] = (uint8_t)(partial >> 8);
    tcp[17] = (uint8_t)partial;
}

static void report(const char *mode, uint64_t frames, size_t frame_length, uint64_t wall_ns,
                   uint64_t cpu, uint64_t stalls)
{
    double seconds = (double)wall_ns / 1e9;
    double bytes = (double)frames * (double)frame_length;
    printf("mode=%s frames=%llu frame_bytes=%zu seconds=%.2f frames_per_s=%.0f MiB_per_s=%.0f "
           "cpu_us_per_frame=%.2f cpu_cores=%.2f stalls=%llu\n",
           mode, (unsigned long long)frames, frame_length, seconds, frames / seconds,
           bytes / seconds / 1048576.0, frames ? (double)cpu / 1000.0 / (double)frames : 0.0,
           (double)cpu / (double)wall_ns, (unsigned long long)stalls);
}

static void set_feeder_buffers(int fd)
{
    int size = FEEDER_SOCKET_BUF;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
}

// Send frames for `seconds`, retrying like the virtio-net worker does when the
// kernel reports a full datagram buffer. Returns frames accepted by the kernel.
static uint64_t feed(int fd, const uint8_t *frame, size_t length, double seconds, uint64_t *stalls)
{
    uint64_t deadline = now_ns() + (uint64_t)(seconds * 1e9);
    uint64_t frames = 0;
    *stalls = 0;
    while (now_ns() < deadline) {
        ssize_t sent = send(fd, frame, length, 0);
        if (sent == (ssize_t)length) {
            frames++;
            continue;
        }
        if (sent < 0 && (errno == ENOBUFS || errno == EAGAIN || errno == EWOULDBLOCK)) {
            (*stalls)++;
            sched_yield();
            continue;
        }
        if (sent < 0 && errno == EINTR) {
            continue;
        }
        fprintf(stderr, "send failed: %s\n", sent < 0 ? strerror(errno) : "short write");
        exit(1);
    }
    return frames;
}

struct drain {
    struct krun_vmnet_bridge *bridge;
    atomic_bool stop;
    atomic_ullong frames;
};

// Production receive + copy path with the vmnet write left out.
static void *drain_socket(void *opaque)
{
    struct drain *drain = opaque;
    while (!atomic_load(&drain->stop)) {
        size_t received = receive_packet_batch(drain->bridge);
        if (received == 0) {
            struct pollfd pollfd = {.fd = drain->bridge->fd, .events = POLLIN};
            (void)poll(&pollfd, 1, 10);
            continue;
        }
        atomic_fetch_add(&drain->frames, received);
    }
    return NULL;
}

static int run_socket(size_t length, double seconds, const uint8_t gateway[4])
{
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) != 0) {
        perror("socketpair");
        return 1;
    }
    set_feeder_buffers(sockets[0]);
    int rcvbuf = KRUN_VMNET_SOCKET_RCVBUF;
    (void)setsockopt(sockets[1], SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    struct krun_vmnet_bridge *bridge = calloc(1, sizeof(*bridge));
    bridge->fd = sockets[1];
    bridge->max_packet_size = KRUN_VMNET_MAX_FRAME_SIZE;
    bridge->socket_rx_buffers = malloc(KRUN_VMNET_SOCKET_RECV_BATCH * KRUN_VMNET_MAX_FRAME_SIZE);
    if (allocate_packet_batch(bridge, KRUN_VMNET_MAX_BATCH_PACKETS,
                              &bridge->tx_buffers, &bridge->tx_iovs, &bridge->tx_packets) != 0) {
        fprintf(stderr, "allocate_packet_batch failed\n");
        return 1;
    }
    struct drain drain = {.bridge = bridge};
    atomic_init(&drain.stop, false);
    atomic_init(&drain.frames, 0);
    pthread_t thread;
    pthread_create(&thread, NULL, drain_socket, &drain);

    uint8_t *frame = malloc(length);
    build_frame(frame, length, gateway, 1);
    uint64_t cpu0 = cpu_ns(), t0 = now_ns(), stalls = 0;
    (void)feed(sockets[0], frame, length, seconds, &stalls);
    uint64_t wall = now_ns() - t0, cpu = cpu_ns() - cpu0;
    atomic_store(&drain.stop, true);
    pthread_join(thread, NULL);
    report("socket", atomic_load(&drain.frames), length, wall, cpu, stalls);
    return 0;
}

// Resolve the gateway MAC like a guest would: ARP request out through the
// bridge, reply back on the socket. Falls back to broadcast if nothing answers.
static void resolve_gateway_mac(int fd, const uint8_t gateway[4])
{
    uint8_t request[42] = {0};
    memset(request, 0xff, 6);
    memcpy(request + 6, GUEST_MAC, 6);
    request[12] = 0x08; request[13] = 0x06;          // ARP
    request[15] = 0x01; request[16] = 0x08;          // Ethernet / IPv4
    request[18] = 6; request[19] = 4; request[21] = 1; // sizes, request
    memcpy(request + 22, GUEST_MAC, 6);
    memcpy(request + 28, GUEST_IP, 4);
    memcpy(request + 38, gateway, 4);
    uint8_t *reply = malloc(KRUN_VMNET_MAX_FRAME_SIZE);
    for (int attempt = 0; attempt < 5; attempt++) {
        (void)send(fd, request, sizeof(request), 0);
        uint64_t deadline = now_ns() + 200000000ull;
        while (now_ns() < deadline) {
            struct pollfd pollfd = {.fd = fd, .events = POLLIN};
            if (poll(&pollfd, 1, 50) <= 0) {
                continue;
            }
            ssize_t length = recv(fd, reply, KRUN_VMNET_MAX_FRAME_SIZE, MSG_DONTWAIT);
            if (length >= 42 && reply[12] == 0x08 && reply[13] == 0x06 && reply[21] == 2
                && memcmp(reply + 28, gateway, 4) == 0) {
                memcpy(GATEWAY_MAC, reply + 22, 6);
                printf("gateway mac=%02x:%02x:%02x:%02x:%02x:%02x\n", GATEWAY_MAC[0], GATEWAY_MAC[1],
                       GATEWAY_MAC[2], GATEWAY_MAC[3], GATEWAY_MAC[4], GATEWAY_MAC[5]);
                free(reply);
                return;
            }
        }
    }
    free(reply);
    // No ARP reply: the shared-mode gateway is a host interface, so take its
    // link-level address from the interface that owns the gateway IP.
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        char owner[IFNAMSIZ] = "";
        for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
            if (entry->ifa_addr != NULL && entry->ifa_addr->sa_family == AF_INET
                && memcmp(&((struct sockaddr_in *)entry->ifa_addr)->sin_addr, gateway, 4) == 0) {
                strncpy(owner, entry->ifa_name, IFNAMSIZ - 1);
            }
        }
        for (struct ifaddrs *entry = list; owner[0] != 0 && entry != NULL; entry = entry->ifa_next) {
            if (entry->ifa_addr != NULL && entry->ifa_addr->sa_family == AF_LINK
                && strcmp(entry->ifa_name, owner) == 0) {
                struct sockaddr_dl *link = (struct sockaddr_dl *)entry->ifa_addr;
                if (link->sdl_alen == 6) {
                    memcpy(GATEWAY_MAC, LLADDR(link), 6);
                    printf("gateway mac=%02x:%02x:%02x:%02x:%02x:%02x from %s\n", GATEWAY_MAC[0],
                           GATEWAY_MAC[1], GATEWAY_MAC[2], GATEWAY_MAC[3], GATEWAY_MAC[4],
                           GATEWAY_MAC[5], owner);
                    freeifaddrs(list);
                    return;
                }
            }
        }
        freeifaddrs(list);
    }
    printf("gateway mac unresolved; using broadcast\n");
}

static int start_bridge(const char *gateway, const char *netmask, int offload, int *fd, void **bridge)
{
    int32_t status = krun_vmnet_start_shared(gateway, netmask, offload, fd, bridge);
    if (status != 0) {
        fprintf(stderr, "krun_vmnet_start_shared failed: %s (%d)\n", strerror(-status), status);
        return 1;
    }
    return 0;
}

static int run_bridge(size_t length, double seconds, const char *gateway, const char *netmask,
                      int offload, const uint8_t gateway_ip[4])
{
    int fd = -1;
    void *opaque = NULL;
    if (start_bridge(gateway, netmask, offload, &fd, &opaque)) {
        return 1;
    }
    struct krun_vmnet_bridge *bridge = opaque;
    resolve_gateway_mac(fd, gateway_ip);
    if (length > bridge->max_packet_size) {
        length = bridge->max_packet_size;
    }
    printf("vmnet max_packet_size=%zu read_batch=%zu write_batch=%zu\n",
           bridge->max_packet_size, bridge->read_batch_size, bridge->write_batch_size);
    set_feeder_buffers(fd);
    uint8_t *frame = malloc(length);
    build_frame(frame, length, gateway_ip, 1);
    uint64_t cpu0 = cpu_ns(), t0 = now_ns(), stalls = 0;
    uint64_t frames = feed(fd, frame, length, seconds, &stalls);
    uint64_t wall = now_ns() - t0, cpu = cpu_ns() - cpu0;
    report("bridge", frames, length, wall, cpu, stalls);
    close(fd);
    krun_vmnet_stop(opaque);
    return 0;
}

#define MAX_LATENCIES (4 * 1024 * 1024)

struct direct_loop {
    struct krun_vmnet_bridge *bridge;
    struct vmpktdesc *packets;
    struct iovec *iovs;
    size_t batch;
    size_t length;
    double seconds;
    uint32_t *latencies;
    size_t calls;
    uint64_t written;
    uint64_t stalls;
    bool failed;
    bool vary_seq;
    uint32_t seq;
    uint64_t interval_ns;
};

// Reads and discards frames the bridge forwards toward the guest side.
struct rx_drain { int fd; atomic_bool stop; uint64_t frames; };
static void *drain_rx_thread(void *opaque)
{
    struct rx_drain *drain = opaque;
    uint8_t *buffer = malloc(KRUN_VMNET_MAX_FRAME_SIZE);
    while (!atomic_load(&drain->stop)) {
        struct pollfd pollfd = {.fd = drain->fd, .events = POLLIN};
        if (poll(&pollfd, 1, 10) <= 0) {
            continue;
        }
        if (recv(drain->fd, buffer, KRUN_VMNET_MAX_FRAME_SIZE, MSG_DONTWAIT) > 0) {
            drain->frames++;
        }
    }
    free(buffer);
    return NULL;
}

static int compare_u32(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

static void *direct_loop_thread(void *opaque)
{
    struct direct_loop *loop = opaque;
    uint64_t deadline = now_ns() + (uint64_t)(loop->seconds * 1e9);
    uint64_t next_send = now_ns();
    while (now_ns() < deadline) {
        if (loop->interval_ns) {
            // Pace each writer like a virtio TX queue fed at a fixed rate.
            while (now_ns() < next_send) {
                sched_yield();
            }
            next_send += loop->interval_ns * loop->batch;
        }
        for (size_t i = 0; i < loop->batch; i++) {
            loop->packets[i].vm_pkt_size = loop->length;
            loop->iovs[i].iov_len = loop->length;
            loop->packets[i].vm_flags = 0;
            if (loop->vary_seq) {
                uint8_t *tcp = (uint8_t *)loop->iovs[i].iov_base + 34;
                loop->seq += (uint32_t)(loop->length - 54);
                tcp[4] = (uint8_t)(loop->seq >> 24); tcp[5] = (uint8_t)(loop->seq >> 16);
                tcp[6] = (uint8_t)(loop->seq >> 8); tcp[7] = (uint8_t)loop->seq;
            }
        }
        int count = (int)loop->batch;
        uint64_t start = now_ns();
        vmnet_return_t status = vmnet_write(loop->bridge->interface, loop->packets, &count);
        uint64_t elapsed = now_ns() - start;
        if (loop->calls < MAX_LATENCIES) {
            loop->latencies[loop->calls++] = (uint32_t)(elapsed / 1000);
        }
        if (status != VMNET_SUCCESS) {
            fprintf(stderr, "vmnet_write failed: %s\n", vmnet_status_name(status));
            loop->failed = true;
            return NULL;
        }
        if (count <= 0) {
            loop->stalls++;
            sched_yield();
            continue;
        }
        loop->written += (uint64_t)count;
    }
    return NULL;
}

static int run_direct(size_t length, double seconds, size_t batch, const char *gateway,
                      const char *netmask, int offload, const uint8_t gateway_ip[4], bool use_thread, bool drain_rx, bool vary_seq,
                      const char *source_memory, size_t threads, uint64_t rate)
{
    int fd = -1;
    void *opaque = NULL;
    if (start_bridge(gateway, netmask, offload, &fd, &opaque)) {
        return 1;
    }
    struct krun_vmnet_bridge *bridge = opaque;
    resolve_gateway_mac(fd, gateway_ip);
    if (length > bridge->max_packet_size) {
        length = bridge->max_packet_size;
    }
    if (batch > bridge->write_batch_size) {
        batch = bridge->write_batch_size;
    }
    // Frame source memory: malloc, or an mmap region like a VMM's guest RAM.
    uint8_t *frames;
    if (strcmp(source_memory, "malloc") == 0) {
        frames = malloc(batch * length);
    } else {
        int flags = MAP_ANON | (strcmp(source_memory, "shared") == 0 ? MAP_SHARED : MAP_PRIVATE);
        frames = mmap(NULL, batch * length, PROT_READ | PROT_WRITE, flags, -1, 0);
        if (frames == MAP_FAILED) { perror("mmap"); return 1; }
    }
    printf("source_memory=%s writers=%zu\n", source_memory, threads);
    struct iovec *iovs = calloc(batch, sizeof(*iovs));
    struct vmpktdesc *packets = calloc(batch, sizeof(*packets));
    for (size_t i = 0; i < batch; i++) {
        build_frame(frames + i * length, length, gateway_ip, (uint32_t)(i + 1));
        iovs[i].iov_base = frames + i * length;
        iovs[i].iov_len = length;
        packets[i].vm_pkt_size = length;
        packets[i].vm_pkt_iov = &iovs[i];
        packets[i].vm_pkt_iovcnt = 1;
    }
    struct direct_loop loop = {
        .bridge = bridge, .packets = packets, .iovs = iovs, .batch = batch, .length = length,
        .seconds = seconds, .latencies = calloc(MAX_LATENCIES, sizeof(uint32_t)),
        .vary_seq = vary_seq, .seq = 1,
        .interval_ns = rate ? 1000000000ull / rate : 0,
    };
    pthread_t drain_thread;
    struct rx_drain drain = {.fd = fd};
    atomic_init(&drain.stop, false);
    if (drain_rx) {
        pthread_create(&drain_thread, NULL, drain_rx_thread, &drain);
    }
    // Extra writers get their own frames, iovecs, and sequence space, and
    // share only the vmnet interface, like independent virtio TX queues would.
    struct direct_loop *loops = calloc(threads, sizeof(*loops));
    pthread_t *writers = calloc(threads, sizeof(*writers));
    loops[0] = loop;
    for (size_t t = 1; t < threads; t++) {
        loops[t] = loop;
        loops[t].latencies = calloc(MAX_LATENCIES, sizeof(uint32_t));
        loops[t].seq = (uint32_t)(t * 0x10000000u);
        uint8_t *copy = malloc(batch * length);
        struct iovec *copy_iovs = calloc(batch, sizeof(*copy_iovs));
        struct vmpktdesc *copy_packets = calloc(batch, sizeof(*copy_packets));
        for (size_t i = 0; i < batch; i++) {
            build_frame(copy + i * length, length, gateway_ip, (uint32_t)(i + 1));
            copy[i * length + 35] = (uint8_t)(0x40 + t); // distinct source port per writer
            copy_iovs[i].iov_base = copy + i * length;
            copy_iovs[i].iov_len = length;
            copy_packets[i].vm_pkt_size = length;
            copy_packets[i].vm_pkt_iov = &copy_iovs[i];
            copy_packets[i].vm_pkt_iovcnt = 1;
        }
        loops[t].iovs = copy_iovs;
        loops[t].packets = copy_packets;
    }
    uint64_t cpu0 = cpu_ns(), t0 = now_ns();
    if (use_thread || threads > 1) {
        for (size_t t = 0; t < threads; t++) {
            pthread_create(&writers[t], NULL, direct_loop_thread, &loops[t]);
        }
        for (size_t t = 0; t < threads; t++) {
            pthread_join(writers[t], NULL);
        }
    } else {
        direct_loop_thread(&loops[0]);
    }
    uint64_t wall = now_ns() - t0, cpu = cpu_ns() - cpu0;
    loop = loops[0];
    for (size_t t = 1; t < threads; t++) {
        loop.written += loops[t].written;
        loop.stalls += loops[t].stalls;
        loop.failed |= loops[t].failed;
    }
    if (drain_rx) {
        atomic_store(&drain.stop, true);
        pthread_join(drain_thread, NULL);
    }
    if (loop.failed) {
        return 1;
    }
    char mode[64];
    snprintf(mode, sizeof(mode), "direct%zu%s%s%s-w%zu-r%llu", batch, use_thread ? "-thread" : "",
             drain_rx ? "-drain" : "", vary_seq ? "-seq" : "", threads, (unsigned long long)rate);
    report(mode, loop.written, length, wall, cpu, loop.stalls);
    if (loop.calls > 0) {
        qsort(loop.latencies, loop.calls, sizeof(uint32_t), compare_u32);
        printf("  writer0 vmnet_write latency us: min=%u p50=%u p90=%u max=%u calls=%zu\n",
               loop.latencies[0], loop.latencies[loop.calls / 2],
               loop.latencies[loop.calls * 9 / 10], loop.latencies[loop.calls - 1], loop.calls);
    }
    close(fd);
    krun_vmnet_stop(opaque);
    return 0;
}

int main(int argc, char **argv)
{
    const char *gateway = "192.168.200.1";
    const char *netmask = "255.255.255.0";
    size_t length = 64800;
    double seconds = 10.0;
    int offload = 1;
    bool use_thread = false;
    bool drain_rx = false;
    bool vary_seq = false;
    const char *source_memory = "malloc";
    size_t threads = 1;
    uint64_t rate = 0;
    int option;
    while ((option = getopt(argc, argv, "g:m:l:s:o:tdqM:T:r:")) != -1) {
        switch (option) {
        case 'g': gateway = optarg; break;
        case 'm': netmask = optarg; break;
        case 'l': length = (size_t)strtoul(optarg, NULL, 10); break;
        case 's': seconds = strtod(optarg, NULL); break;
        case 'o': offload = atoi(optarg); break;
        case 't': use_thread = true; break;
        case 'd': drain_rx = true; break;
        case 'q': vary_seq = true; break;
        case 'M': source_memory = optarg; break;
        case 'r': rate = strtoull(optarg, NULL, 10); break;
        case 'T': threads = (size_t)strtoul(optarg, NULL, 10); if (threads == 0) threads = 1; break;
        default:
            fprintf(stderr, "usage: %s [-g gateway] [-m netmask] [-l frame_bytes] [-s seconds] [-o 0|1] [-t] [-d] [-q] [-M malloc|private|shared] [-T writers] [-r frames_per_s_per_writer] socket|bridge|direct N\n", argv[0]);
            return 2;
        }
    }
    if (optind >= argc) {
        fprintf(stderr, "missing mode\n");
        return 2;
    }
    struct in_addr gateway_addr;
    if (inet_pton(AF_INET, gateway, &gateway_addr) != 1) {
        fprintf(stderr, "invalid gateway\n");
        return 2;
    }
    uint8_t gateway_ip[4];
    memcpy(gateway_ip, &gateway_addr.s_addr, 4);
    if (length < 64 || length > KRUN_VMNET_MAX_FRAME_SIZE) {
        fprintf(stderr, "frame length out of range\n");
        return 2;
    }
    const char *mode = argv[optind];
    if (strcmp(mode, "socket") == 0) {
        return run_socket(length, seconds, gateway_ip);
    }
    if (strcmp(mode, "bridge") == 0) {
        return run_bridge(length, seconds, gateway, netmask, offload, gateway_ip);
    }
    if (strcmp(mode, "direct") == 0) {
        size_t batch = optind + 1 < argc ? (size_t)strtoul(argv[optind + 1], NULL, 10) : 1;
        if (batch == 0) {
            batch = 1;
        }
        return run_direct(length, seconds, batch, gateway, netmask, offload, gateway_ip, use_thread, drain_rx, vary_seq, source_memory, threads, rate);
    }
    fprintf(stderr, "unknown mode %s\n", mode);
    return 2;
}
