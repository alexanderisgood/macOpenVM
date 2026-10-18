/* SPDX-License-Identifier: Apache-2.0 */
/* Original bounded health-only transport. Installation is verified separately. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/vm_sockets.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include "../Protocol/generated/agent_v1.h"

#define LAB_PORT 4050u
#define FILE_LIMIT 65536
#define SERVICE_WINDOW_MS 60000
#define SERVICE_CONNECTIONS 32u
#define SERVICE_BAD_CONNECTIONS 8u
#define SERVICE_LOGS 64u
#define SERVICE_LOG_BYTES 16384
#ifndef MVO_AGENT_LAB_PATCH_VERSION
#define MVO_AGENT_LAB_PATCH_VERSION 0
#endif
#if MVO_AGENT_LAB_PATCH_VERSION != 0 && MVO_AGENT_LAB_PATCH_VERSION != 1
#error "Only qualified lab patch versions 0 and 1 are accepted"
#endif
#if MVO_AGENT_LAB_PATCH_VERSION == 1
#define LAB_HEALTH_EVENT "mvo.agent-tls.health-complete version=0.1.1 architecture=arm64"
#else
#define LAB_HEALTH_EVENT "mvo.agent-tls.health-complete version=0.1.0 architecture=arm64"
#endif
static volatile sig_atomic_t stopping;
static sigset_t service_wait_mask;
static int service_signals_blocked;

static void stop_service(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static int install_service_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = stop_service;
    if (sigemptyset(&action.sa_mask) != 0) return 0;
    /* No SA_RESTART: a termination request interrupts the event-driven waits. */
    if (sigaction(SIGTERM, &action, NULL) != 0 || sigaction(SIGINT, &action, NULL) != 0) return 0;
    sigset_t blocked;
    if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGTERM) != 0 ||
        sigaddset(&blocked, SIGINT) != 0 ||
        sigprocmask(SIG_BLOCK, &blocked, &service_wait_mask) != 0 ||
        sigdelset(&service_wait_mask, SIGTERM) != 0 || sigdelset(&service_wait_mask, SIGINT) != 0) return 0;
    service_signals_blocked = 1;
    return 1;
}

static void emit_line(int fd, int service, unsigned *logs, const char *event, int final) {
    /* Reserve one process-exit event, and bound the actual inherited log file
       across supervisor respawns. Never open or truncate a log path ourselves. */
    if (service && *logs >= (final ? SERVICE_LOGS : SERVICE_LOGS - 1)) return;
    size_t length = strnlen(event, 129);
    if (length == 0 || length > 128) return;
    struct stat info;
    if (fstat(fd, &info) != 0) return;
    if (service && S_ISREG(info.st_mode)) {
        int flags = fcntl(fd, F_GETFL);
        if (flags < 0 || (flags & O_APPEND) == 0 || (info.st_mode & 07777) != 0600 ||
            (info.st_uid != 0 && info.st_uid != geteuid()) || info.st_size < 0 ||
            info.st_size > SERVICE_LOG_BYTES - (off_t)(length + 1)) return;
    }
    char line[130];
    memcpy(line, event, length);
    line[length++] = '\n';
    if (service) ++*logs;
    /* One supervised process writes one complete fixed/sanitized line at once. */
    (void)write(fd, line, length);
}

static void event_log(int service, unsigned *logs, const char *event) {
    emit_line(STDOUT_FILENO, service, logs, event, 0);
}

static int event_poll(struct pollfd *items, nfds_t count, int milliseconds) {
    if (!service_signals_blocked) return poll(items, count, milliseconds);
    struct timespec timeout = { .tv_sec = milliseconds < 0 ? 0 : milliseconds / 1000,
                               .tv_nsec = milliseconds < 0 ? 0 : (milliseconds % 1000) * 1000000L };
    /* Atomically expose pending termination signals only while entering the wait. */
    return ppoll(items, count, milliseconds < 0 ? NULL : &timeout, &service_wait_mask);
}

static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static int wait_fd(int fd, short events, int64_t deadline) {
    for (;;) {
        if (stopping) return 0;
        int64_t now = now_ms();
        if (now < 0 || now >= deadline) return 0;
        int64_t remaining = deadline - now;
        struct pollfd item = { .fd = fd, .events = events, .revents = 0 };
        int timeout = deadline == INT64_MAX ? -1 : remaining > INT_MAX ? INT_MAX : (int)remaining;
        int ready = event_poll(&item, 1, timeout);
        if (ready < 0 && errno == EINTR) continue;
        return ready > 0 && (item.revents & events) != 0;
    }
}

static int cooldown_until(int64_t deadline) {
    while (!stopping) {
        int64_t now = now_ms();
        if (now < 0) return 0;
        if (now >= deadline) return 1;
        int64_t remaining = deadline - now;
        int result = event_poll(NULL, 0, remaining > INT_MAX ? INT_MAX : (int)remaining);
        if (result < 0 && errno != EINTR) return 0;
    }
    return 0;
}

static int tls_retry(SSL *ssl, int result, int fd, int64_t deadline) {
    int error = SSL_get_error(ssl, result);
    if (error == SSL_ERROR_WANT_READ) return wait_fd(fd, POLLIN, deadline);
    if (error == SSL_ERROR_WANT_WRITE) return wait_fd(fd, POLLOUT, deadline);
    return 0;
}

static int tls_io(SSL *ssl, int fd, uint8_t *bytes, size_t length, int writing, int64_t deadline) {
    size_t offset = 0;
    while (offset < length) {
        if (stopping || now_ms() < 0 || now_ms() >= deadline) return 0;
        size_t count = 0;
        int result = writing ? SSL_write_ex(ssl, bytes + offset, length - offset, &count)
                             : SSL_read_ex(ssl, bytes + offset, length - offset, &count);
        if (result == 1) {
            if (count == 0 || count > length - offset) return 0;
            offset += count;
        } else if (!tls_retry(ssl, result, fd, deadline)) return 0;
    }
    return 1;
}

static int read_frame(SSL *ssl, int fd, mvo_agent_frame *frame, int64_t deadline) {
    uint8_t bytes[MVO_AGENT_MAX_FRAME_BYTES];
    if (!tls_io(ssl, fd, bytes, MVO_AGENT_HEADER_BYTES, 0, deadline)) return 0;
    size_t length = mvo_agent_frame_length(bytes, MVO_AGENT_HEADER_BYTES);
    if (length < MVO_AGENT_HEADER_BYTES || length > sizeof(bytes)) return 0;
    if (!tls_io(ssl, fd, bytes + MVO_AGENT_HEADER_BYTES,
                length - MVO_AGENT_HEADER_BYTES, 0, deadline)) return 0;
    return mvo_agent_decode(bytes, length, frame);
}

static int write_frame(SSL *ssl, int fd, const mvo_agent_frame *frame, int64_t deadline) {
    uint8_t bytes[MVO_AGENT_MAX_FRAME_BYTES];
    size_t length = mvo_agent_encode(frame, bytes, sizeof(bytes));
    return length != 0 && tls_io(ssl, fd, bytes, length, 1, deadline);
}

static int nonzero(const uint8_t value[16]) {
    uint8_t any = 0;
    for (size_t i = 0; i < 16; ++i) any |= value[i];
    return any != 0;
}

static int health_exchange(SSL *ssl, int fd, const uint8_t expected_vm[16], int64_t deadline) {
    mvo_agent_frame request, response;
    if (!read_frame(ssl, fd, &request, deadline) || request.kind != MVO_AGENT_HELLO) return 0;
    const mvo_agent_hello hello = request.body.hello;
    if (hello.sequence != 0 || !nonzero(hello.session_id) || !nonzero(hello.request_id) ||
        memcmp(hello.vm_id, expected_vm, 16) != 0 ||
        (hello.supported_features & MVO_AGENT_FEATURE_HEALTH) == 0 ||
        (hello.required_features & ~MVO_AGENT_FEATURE_HEALTH) != 0 ||
        (hello.required_features & ~hello.supported_features) != 0) return 0;
    memset(&response, 0, sizeof(response));
    response.kind = MVO_AGENT_HELLO_REPLY;
    memcpy(response.body.hello_reply.session_id, hello.session_id, 16);
    memcpy(response.body.hello_reply.request_id, hello.request_id, 16);
    memcpy(response.body.hello_reply.vm_id, expected_vm, 16);
    response.body.hello_reply.selected_features = MVO_AGENT_FEATURE_HEALTH;
    response.body.hello_reply.agent_minor = 1;
    response.body.hello_reply.agent_patch = MVO_AGENT_LAB_PATCH_VERSION;
    response.body.hello_reply.architecture = 1;
    if (!write_frame(ssl, fd, &response, deadline) || !read_frame(ssl, fd, &request, deadline) ||
        request.kind != MVO_AGENT_HEALTH_REQUEST) return 0;
    const mvo_agent_health_request health = request.body.health_request;
    if (health.sequence != 1 || !nonzero(health.request_id) ||
        memcmp(health.session_id, hello.session_id, 16) != 0 ||
        memcmp(health.request_id, hello.request_id, 16) == 0) return 0;
    memset(&response, 0, sizeof(response));
    response.kind = MVO_AGENT_HEALTH_REPLY;
    memcpy(response.body.health_reply.session_id, health.session_id, 16);
    memcpy(response.body.health_reply.request_id, health.request_id, 16);
    response.body.health_reply.sequence = 1;
    response.body.health_reply.agent_minor = 1;
    response.body.health_reply.agent_patch = MVO_AGENT_LAB_PATCH_VERSION;
    response.body.health_reply.architecture = 1;
    response.body.health_reply.status = 1;
    return write_frame(ssl, fd, &response, deadline);
}

static int hex_digit(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

static int parse_vm_id(const char *text, uint8_t value[16]) {
    if (strlen(text) != 36) return 0;
    size_t position = 0;
    for (size_t i = 0; i < 36;) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (text[i++] != '-') return 0;
            continue;
        }
        int high = hex_digit(text[i++]);
        int low = hex_digit(text[i++]);
        if (high < 0 || low < 0 || position >= 16) return 0;
        value[position++] = (uint8_t)((high << 4) | low);
    }
    return position == 16 && nonzero(value);
}

static int service_file(const char *path, int private_key) {
    size_t length = strnlen(path, 4097);
    if (length < 2 || length > 4096 || path[0] != '/') return -1;
    char components[4097];
    memcpy(components, path, length + 1);
    for (size_t i = 0; i < length; ++i) {
        unsigned char value = (unsigned char)path[i];
        if (value < 32 || value == 127) return -1;
    }
    int directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (directory < 0) return -1;
    char *component = components + 1;
    for (;;) {
        char *slash = strchr(component, '/');
        if (slash != NULL) *slash = '\0';
        if (*component == '\0' || strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
            close(directory); return -1;
        }
        struct stat parent;
        if (fstat(directory, &parent) != 0 || !S_ISDIR(parent.st_mode) ||
            (parent.st_uid != 0 && parent.st_uid != geteuid()) || (parent.st_mode & 0022) != 0) {
            close(directory); return -1;
        }
        if (slash != NULL) {
            int next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            close(directory);
            if (next < 0) return -1;
            directory = next;
            component = slash + 1;
            continue;
        }
        if (parent.st_uid != geteuid() || (parent.st_mode & 07777) != 0700) {
            close(directory); return -1;
        }
        int fd = openat(directory, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        struct stat info, named;
        int admitted = fd >= 0 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
                       info.st_uid == geteuid() && info.st_nlink == 1 &&
                       (info.st_mode & 07777) == (private_key ? 0600 : 0400) &&
                       info.st_size > 0 && info.st_size <= FILE_LIMIT &&
                       fstatat(directory, component, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                       named.st_dev == info.st_dev && named.st_ino == info.st_ino;
        close(directory);
        if (!admitted) { if (fd >= 0) close(fd); return -1; }
        return fd;
    }
}

static BIO *input_file(const char *path, int service, int private_key) {
    if (path[0] != '/' || strlen(path) > 4096) return NULL;
    int fd = service ? service_file(path, private_key)
                     : open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > FILE_LIMIT) {
        close(fd);
        return NULL;
    }
    BIO *bio = BIO_new_fd(fd, BIO_CLOSE);
    if (bio == NULL) close(fd);
    return bio;
}

static int no_password(char *buffer, int size, int writing, void *argument) {
    (void)buffer; (void)size; (void)writing; (void)argument;
    return 0;
}

static SSL_CTX *make_context(const char *cert_path, const char *key_path, const char *ca_path, int service) {
    SSL_CTX *context = NULL;
    X509 *cert = NULL, *ca = NULL;
    EVP_PKEY *key = NULL;
    BIO *bio = input_file(cert_path, service, 0);
    if (bio == NULL) goto done;
    cert = PEM_read_bio_X509(bio, NULL, no_password, NULL);
    BIO_free(bio);
    bio = input_file(key_path, service, 1);
    if (bio == NULL) goto done;
    key = PEM_read_bio_PrivateKey(bio, NULL, no_password, NULL);
    BIO_free(bio);
    bio = input_file(ca_path, service, 0);
    if (bio == NULL) goto done;
    ca = PEM_read_bio_X509(bio, NULL, no_password, NULL);
    BIO_free(bio);
    bio = NULL;
    if (cert == NULL || ca == NULL || key == NULL) goto done;
    context = SSL_CTX_new(TLS_server_method());
    if (context == NULL) goto done;
    SSL_CTX_set_verify(context, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);
    SSL_CTX_set_verify_depth(context, 2);
    SSL_CTX_set_session_cache_mode(context, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_options(context, SSL_OP_NO_TICKET);
    if (!SSL_CTX_set_min_proto_version(context, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(context, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_early_data(context, 0) || !SSL_CTX_set_recv_max_early_data(context, 0) ||
        !SSL_CTX_set_num_tickets(context, 0) || !SSL_CTX_set_purpose(context, X509_PURPOSE_SSL_CLIENT) ||
        !SSL_CTX_use_certificate(context, cert) || !SSL_CTX_use_PrivateKey(context, key) ||
        !SSL_CTX_check_private_key(context) ||
        !X509_STORE_add_cert(SSL_CTX_get_cert_store(context), ca)) {
        SSL_CTX_free(context);
        context = NULL;
    }
done:
    BIO_free(bio);
    X509_free(cert); X509_free(ca); EVP_PKEY_free(key);
    return context;
}

int main(int argc, char **argv) {
    uint8_t expected_vm[16];
    unsigned clients = 2;
    unsigned logs = 0;
    int service = argc == 6 && strcmp(argv[5], "--service") == 0;
    if ((argc != 5 && argc != 6) || !parse_vm_id(argv[4], expected_vm)) goto configuration_error;
    if (service && geteuid() == 0) {
        emit_line(STDERR_FILENO, service, &logs, "mvo.agent-tls.failure stage=privilege", 1);
        return 1;
    }
    if (service && !install_service_signals()) goto configuration_error;
    if (argc == 6 && !service) {
        if (strlen(argv[5]) != 1 || argv[5][0] < '1' || argv[5][0] > '8') goto configuration_error;
        clients = (unsigned)(argv[5][0] - '0');
    }
    if (!OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL)) goto configuration_error;
    SSL_CTX *context = make_context(argv[1], argv[2], argv[3], service);
    if (context == NULL) goto configuration_error;
    if (stopping) { SSL_CTX_free(context); return 0; }
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) { SSL_CTX_free(context); goto configuration_error; }
    int listener = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    struct sockaddr_vm address;
    memset(&address, 0, sizeof(address));
    address.svm_family = AF_VSOCK;
    address.svm_cid = VMADDR_CID_ANY;
    address.svm_port = LAB_PORT;
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listener, 1) != 0) {
        if (listener >= 0) close(listener);
        SSL_CTX_free(context);
        emit_line(STDERR_FILENO, service, &logs, "mvo.agent-tls.failure stage=listen", 1);
        return 2;
    }
    event_log(service, &logs, "mvo.agent-tls.ready port=4050 version=1");
    uint64_t healthy = 0;
    unsigned handled = 0, window_connections = 0, window_bad = 0;
    if (service) {
        const char *version = OpenSSL_version(OPENSSL_VERSION);
        size_t length = version == NULL ? 0 : strnlen(version, 97);
        int safe = length > 0 && length <= 96 && strncmp(version, "OpenSSL ", 8) == 0;
        for (size_t i = 0; safe && i < length; ++i) {
            unsigned char value = (unsigned char)version[i];
            if (value < 32 || value > 126 || value == '/' || value == '\\') safe = 0;
        }
        if (safe) {
            char event[160];
            int written = snprintf(event, sizeof(event), "mvo.agent-tls.runtime openssl=%s", version);
            if (written > 0 && (size_t)written < sizeof(event)) event_log(service, &logs, event);
        } else event_log(service, &logs, "mvo.agent-tls.runtime unavailable");
    }
    int64_t began = now_ms();
    int64_t window_started = began;
    int service_error = began < 0;
    while (began >= 0 && !stopping && (service || handled < clients)) {
        if (service) {
            int64_t now = now_ms();
            if (now < 0) { service_error = 1; break; }
            if (now - window_started >= SERVICE_WINDOW_MS) {
                window_started = now; window_connections = 0; window_bad = 0;
            }
            if (window_connections >= SERVICE_CONNECTIONS || window_bad >= SERVICE_BAD_CONNECTIONS) {
                event_log(service, &logs, "mvo.agent-tls.service-rate-limited");
                if (!cooldown_until(window_started + SERVICE_WINDOW_MS)) {
                    if (!stopping) service_error = 1;
                    break;
                }
                continue;
            }
        }
        if (!wait_fd(listener, POLLIN, service ? INT64_MAX : began + 120000)) {
            if (service && !stopping) service_error = 1;
            break;
        }
        if (service) {
            int64_t now = now_ms();
            if (now < 0) { service_error = 1; break; }
            if (now - window_started >= SERVICE_WINDOW_MS) {
                window_started = now; window_connections = 0; window_bad = 0;
            }
        }
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (fd < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            if (service) service_error = 1;
            break;
        }
        if (!service) ++handled;
        if (service) ++window_connections;
        SSL *ssl = SSL_new(context);
        int accepted = 0;
        int64_t deadline = now_ms() + 15000;
        if (ssl != NULL && SSL_set_fd(ssl, fd) == 1) {
            for (;;) {
                if (stopping || now_ms() >= deadline) break;
                int result = SSL_accept(ssl);
                if (result == 1) { accepted = 1; break; }
                if (!tls_retry(ssl, result, fd, deadline)) break;
            }
        }
        X509 *peer = accepted ? SSL_get1_peer_certificate(ssl) : NULL;
        accepted = accepted && peer != NULL && SSL_get_verify_result(ssl) == X509_V_OK &&
                   SSL_version(ssl) == TLS1_3_VERSION && !SSL_session_reused(ssl) &&
                   X509_check_host(peer, "macopenvm-host.invalid", 0,
                     X509_CHECK_FLAG_NEVER_CHECK_SUBJECT | X509_CHECK_FLAG_NO_WILDCARDS, NULL) == 1;
        X509_free(peer);
        if (!accepted) {
            if (service) ++window_bad;
            event_log(service, &logs, "mvo.agent-tls.rejected category=tls");
        }
        else if (health_exchange(ssl, fd, expected_vm, now_ms() + 10000)) {
            if (healthy < UINT64_MAX) ++healthy;
            event_log(service, &logs, LAB_HEALTH_EVENT);
        } else {
            if (service) ++window_bad;
            event_log(service, &logs, "mvo.agent-tls.rejected category=protocol");
        }
        if (ssl != NULL && SSL_is_init_finished(ssl) && !stopping) {
            int64_t shutdown_deadline = now_ms() + 1000;
            for (;;) {
                int result = SSL_shutdown(ssl);
                if (result == 1) break;
                if (result == 0) { if (!wait_fd(fd, POLLIN, shutdown_deadline)) break; }
                else if (!tls_retry(ssl, result, fd, shutdown_deadline)) break;
            }
        }
        SSL_free(ssl); close(fd);
    }
    close(listener); SSL_CTX_free(context);
    if (service) {
        emit_line(STDOUT_FILENO, service, &logs,
                  stopping ? "mvo.agent-tls.service-stopped" : "mvo.agent-tls.failure stage=service", 1);
        return stopping && !service_error ? 0 : 4;
    }
    char completed[96];
    (void)snprintf(completed, sizeof(completed), "mvo.agent-tls.complete health=%llu", (unsigned long long)healthy);
    emit_line(STDOUT_FILENO, 0, &logs, completed, 1);
    return healthy > 0 ? 0 : 3;
configuration_error:
    emit_line(STDERR_FILENO, service, &logs, "mvo.agent-tls.failure stage=configuration", 1);
    return 1;
}
