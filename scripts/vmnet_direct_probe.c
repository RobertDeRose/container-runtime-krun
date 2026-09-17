// Experimental probe for macOS 26 vmnet network-reference ownership.
//
// This intentionally creates and consumes the vmnet_network_ref in the same
// process. It does not use Apple's serialized network handoff and it does not
// require libkrun. The only question it answers is whether this process can
// create a logical vmnet network and attach an interface to it.

#include <AvailabilityMacros.h>
#include <arpa/inet.h>
#include <errno.h>
#include <grp.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>
#include <vmnet/vmnet.h>
#include <xpc/xpc.h>

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 260000
#error "vmnet_direct_probe requires the macOS 26 SDK or newer"
#endif

static const uint64_t timeout_ns = 10ULL * NSEC_PER_SEC;

struct privilege_drop {
    bool requested;
    uid_t uid;
    gid_t gid;
};

static const char *status_name(vmnet_return_t status)
{
    switch (status) {
    case VMNET_SUCCESS:
        return "VMNET_SUCCESS";
    case VMNET_FAILURE:
        return "VMNET_FAILURE";
    case VMNET_MEM_FAILURE:
        return "VMNET_MEM_FAILURE";
    case VMNET_INVALID_ARGUMENT:
        return "VMNET_INVALID_ARGUMENT";
    case VMNET_SETUP_INCOMPLETE:
        return "VMNET_SETUP_INCOMPLETE";
    case VMNET_INVALID_ACCESS:
        return "VMNET_INVALID_ACCESS";
    case VMNET_PACKET_TOO_BIG:
        return "VMNET_PACKET_TOO_BIG";
    case VMNET_BUFFER_EXHAUSTED:
        return "VMNET_BUFFER_EXHAUSTED";
    case VMNET_TOO_MANY_PACKETS:
        return "VMNET_TOO_MANY_PACKETS";
    default:
        return "VMNET_UNKNOWN_STATUS";
    }
}

static void print_status(const char *key, vmnet_return_t status)
{
    printf("%s=%s(%d)\n", key, status_name(status), status);
    fflush(stdout);
}

static int wait_semaphore(dispatch_semaphore_t semaphore)
{
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ns);
    return dispatch_semaphore_wait(semaphore, deadline) == 0 ? 0 : -1;
}

static int print_network(vmnet_network_ref network)
{
    struct in_addr subnet = {0};
    struct in_addr mask = {0};
    struct in6_addr prefix = {0};
    uint8_t prefix_len = 0;
    char subnet_text[INET_ADDRSTRLEN] = {0};
    char mask_text[INET_ADDRSTRLEN] = {0};
    char prefix_text[INET6_ADDRSTRLEN] = {0};

    if (__builtin_available(macOS 26.0, *)) {
        vmnet_network_get_ipv4_subnet(network, &subnet, &mask);
        vmnet_network_get_ipv6_prefix(network, &prefix, &prefix_len);
    } else {
        fprintf(stderr, "macOS 26 or newer is required\n");
        return -1;
    }

    if (inet_ntop(AF_INET, &subnet, subnet_text, sizeof(subnet_text)) == NULL
        || inet_ntop(AF_INET, &mask, mask_text, sizeof(mask_text)) == NULL
        || inet_ntop(AF_INET6, &prefix, prefix_text, sizeof(prefix_text)) == NULL) {
        perror("inet_ntop");
        return -1;
    }

    printf("ipv4_subnet=%s\n", subnet_text);
    printf("ipv4_mask=%s\n", mask_text);
    printf("ipv6_prefix=%s\n", prefix_text);
    printf("ipv6_prefix_length=%u\n", prefix_len);
    fflush(stdout);
    return 0;
}


static int query_network_after_drop(vmnet_network_ref network)
{
    struct in_addr subnet = {0};
    struct in_addr mask = {0};
    struct in6_addr prefix = {0};
    uint8_t prefix_len = 0;

    if (__builtin_available(macOS 26.0, *)) {
        vmnet_network_get_ipv4_subnet(network, &subnet, &mask);
        vmnet_network_get_ipv6_prefix(network, &prefix, &prefix_len);
    } else {
        return 30;
    }

    bool has_ipv4 = subnet.s_addr != 0 && mask.s_addr != 0;
    bool has_ipv6 = prefix_len != 0 && !IN6_IS_ADDR_UNSPECIFIED(&prefix);
    printf("post_drop_network_query=%d\n", has_ipv4 && has_ipv6 ? 1 : 0);
    printf("post_drop_ipv6_prefix_length=%u\n", prefix_len);
    fflush(stdout);
    return has_ipv4 && has_ipv6 ? 0 : 31;
}

static int write_probe_frame(interface_ref interface, uint64_t max_packet_size)
{
    // vmnet_write() exercises the same guest-to-host data-plane primitive used
    // by vmnet-helper. The experimental EtherType keeps the frame inert even
    // if another endpoint happens to observe the broadcast.
    unsigned char frame[64] = {0};
    if (max_packet_size < sizeof(frame)) {
        fprintf(stderr, "vmnet max packet size is unexpectedly small\n");
        return 32;
    }

    memset(frame, 0xff, 6);
    frame[6] = 0x02;
    frame[11] = 0x01;
    frame[12] = 0x88;
    frame[13] = 0xb5;
    const char payload[] = "container-runtime-krun privilege-drop probe";
    memcpy(&frame[14], payload, sizeof(payload) - 1);

    struct iovec iov = {
        .iov_base = frame,
        .iov_len = sizeof(frame),
    };
    struct vmpktdesc packet = {0};
    packet.vm_pkt_size = sizeof(frame);
    packet.vm_pkt_iov = &iov;
    packet.vm_pkt_iovcnt = 1;

    int packet_count = 1;
    vmnet_return_t status = vmnet_write(interface, &packet, &packet_count);
    print_status("post_drop_vmnet_write_status", status);
    printf("post_drop_vmnet_write_count=%d\n", packet_count);
    fflush(stdout);

    if (status != VMNET_SUCCESS || packet_count != 1) {
        return 33;
    }
    return 0;
}

static int drop_privileges(struct privilege_drop drop)
{
    if (!drop.requested) {
        printf("privilege_drop_requested=0\n");
        fflush(stdout);
        return 0;
    }

    printf("privilege_drop_requested=1\n");
    printf("pre_drop_euid=%u\n", geteuid());
    printf("pre_drop_egid=%u\n", getegid());
    printf("target_uid=%u\n", drop.uid);
    printf("target_gid=%u\n", drop.gid);
    fflush(stdout);

    if (geteuid() != 0) {
        fprintf(stderr, "privilege drop requires an initial effective uid of 0\n");
        return 34;
    }
    if (setgroups(0, NULL) != 0) {
        perror("setgroups");
        return 35;
    }
    if (setgid(drop.gid) != 0) {
        perror("setgid");
        return 36;
    }
    if (setuid(drop.uid) != 0) {
        perror("setuid");
        return 37;
    }

    printf("post_drop_euid=%u\n", geteuid());
    printf("post_drop_egid=%u\n", getegid());
    fflush(stdout);
    if (geteuid() != drop.uid || getegid() != drop.gid) {
        return 38;
    }

    errno = 0;
    if (seteuid(0) == 0) {
        fprintf(stderr, "unexpectedly regained root after permanent privilege drop\n");
        return 39;
    }
    printf("root_regain_blocked=%d\n", errno == EPERM ? 1 : 0);
    fflush(stdout);
    return errno == EPERM ? 0 : 40;
}

static int stop_interface(interface_ref interface, dispatch_queue_t queue)
{
    __block vmnet_return_t callback_status = VMNET_SETUP_INCOMPLETE;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    vmnet_return_t status = vmnet_stop_interface(
        interface,
        queue,
        ^(vmnet_return_t value) {
            callback_status = value;
            dispatch_semaphore_signal(completed);
        }
    );
    print_status("interface_stop_submit_status", status);
    if (status != VMNET_SUCCESS) {
        return 25;
    }
    if (wait_semaphore(completed) != 0) {
        fprintf(stderr, "timed out waiting for vmnet_stop_interface\n");
        return 26;
    }
    print_status("interface_stop_status", callback_status);
    return callback_status == VMNET_SUCCESS ? 0 : 27;
}

static int run_probe_available(
    vmnet_mode_t mode,
    const char *mode_name,
    struct privilege_drop drop
) __attribute__((availability(macos, introduced = 26.0)));

static int run_probe_available(
    vmnet_mode_t mode,
    const char *mode_name,
    struct privilege_drop drop
)
{
    vmnet_return_t status = VMNET_FAILURE;
    vmnet_network_configuration_ref configuration = NULL;
    vmnet_network_ref network = NULL;
    interface_ref interface = NULL;
    dispatch_queue_t queue = dispatch_queue_create(
        "com.github.robertderose.container-runtime-krun.vmnet-probe",
        DISPATCH_QUEUE_SERIAL
    );

    printf("euid=%u\n", geteuid());
    printf("egid=%u\n", getegid());
    printf("mode=%s\n", mode_name);
    fflush(stdout);

    configuration = vmnet_network_configuration_create(mode, &status);
    print_status("network_configuration_create_status", status);
    if (configuration == NULL || status != VMNET_SUCCESS) {
        return 20;
    }

    // Match Apple's reserved-network setup: allocation is owned by the caller,
    // not vmnet DHCP, so the interface can later receive the exact attachment
    // addresses chosen by the container network service.
    vmnet_network_configuration_disable_dhcp(configuration);

    network = vmnet_network_create(configuration, &status);
    print_status("network_create_status", status);
    CFRelease(configuration);
    configuration = NULL;
    if (network == NULL || status != VMNET_SUCCESS) {
        return 21;
    }
    if (print_network(network) != 0) {
        return 22;
    }

    xpc_object_t descriptor = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_bool(descriptor, vmnet_allocate_mac_address_key, true);
    xpc_dictionary_set_bool(descriptor, vmnet_enable_isolation_key, true);
    xpc_dictionary_set_bool(descriptor, vmnet_enable_tso_key, true);
    xpc_dictionary_set_bool(descriptor, vmnet_enable_checksum_offload_key, true);

    __block vmnet_return_t callback_status = VMNET_SETUP_INCOMPLETE;
    __block uint64_t max_packet_size = 0;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    interface = vmnet_interface_start_with_network(
        network,
        descriptor,
        queue,
        ^(vmnet_return_t value, xpc_object_t parameters) {
            callback_status = value;
            if (parameters != NULL) {
                max_packet_size = xpc_dictionary_get_uint64(parameters, vmnet_max_packet_size_key);
            }
            dispatch_semaphore_signal(completed);
        }
    );
    xpc_release(descriptor);

    printf("interface_ref_created=%d\n", interface != NULL ? 1 : 0);
    fflush(stdout);
    if (interface == NULL) {
        fprintf(stderr, "vmnet_interface_start_with_network returned NULL\n");
        return 23;
    }
    if (wait_semaphore(completed) != 0) {
        fprintf(stderr, "timed out waiting for vmnet_interface_start_with_network\n");
        return 24;
    }

    print_status("interface_start_status", callback_status);
    printf("max_packet_size=%llu\n", (unsigned long long)max_packet_size);
    fflush(stdout);
    if (callback_status != VMNET_SUCCESS) {
        return 24;
    }

    int probe_status = drop_privileges(drop);
    if (probe_status == 0 && drop.requested) {
        probe_status = query_network_after_drop(network);
    }
    if (probe_status == 0 && drop.requested) {
        probe_status = write_probe_frame(interface, max_packet_size);
    }

    // Teardown is intentionally performed after the privilege drop too. A
    // successful stop proves the retained interface can still be controlled by
    // the unprivileged process, not merely written once.
    int stop_status = stop_interface(interface, queue);
    CFRelease(network);
    network = NULL;
    printf("probe_complete=%d\n", probe_status == 0 && stop_status == 0 ? 1 : 0);
    fflush(stdout);
    return probe_status != 0 ? probe_status : stop_status;
}

static int run_probe(
    vmnet_mode_t mode,
    const char *mode_name,
    struct privilege_drop drop
)
{
    if (__builtin_available(macOS 26.0, *)) {
        return run_probe_available(mode, mode_name, drop);
    }

    fprintf(stderr, "macOS 26 or newer is required\n");
    return 10;
}

static void usage(const char *program)
{
    fprintf(
        stderr,
        "usage: %s --mode host|shared [--drop-uid UID --drop-gid GID]\n",
        program
    );
}

static int parse_id(const char *value, uint32_t *result)
{
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
        return -1;
    }
    *result = (uint32_t)parsed;
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = NULL;
    bool have_uid = false;
    bool have_gid = false;
    uint32_t drop_uid = 0;
    uint32_t drop_gid = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            mode = argv[++i];
        } else if (strcmp(argv[i], "--drop-uid") == 0 && i + 1 < argc) {
            if (parse_id(argv[++i], &drop_uid) != 0) {
                usage(argv[0]);
                return 2;
            }
            have_uid = true;
        } else if (strcmp(argv[i], "--drop-gid") == 0 && i + 1 < argc) {
            if (parse_id(argv[++i], &drop_gid) != 0) {
                usage(argv[0]);
                return 2;
            }
            have_gid = true;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (mode == NULL || have_uid != have_gid) {
        usage(argv[0]);
        return 2;
    }

    struct privilege_drop drop = {
        .requested = have_uid && have_gid,
        .uid = (uid_t)drop_uid,
        .gid = (gid_t)drop_gid,
    };

    if (strcmp(mode, "host") == 0) {
        return run_probe(VMNET_HOST_MODE, "host", drop);
    }
    if (strcmp(mode, "shared") == 0) {
        return run_probe(VMNET_SHARED_MODE, "shared", drop);
    }

    usage(argv[0]);
    return 2;
}
