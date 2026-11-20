/*
 * fpm-ping: the FPM healthcheck probe, installed as php-fpm-healthcheck.
 *
 * Sends one FastCGI responder request for the pool's ping.path and exits 0 when
 * the response contains the expected text, 1 otherwise (one line on stderr).
 *
 *   PHP_FPM_LISTEN         pool listen address, default 127.0.0.1:9000. HOST:PORT,
 *                          [V6]:PORT, a bare PORT or a unix socket path; a wildcard
 *                          bind address (0.0.0.0, ::) is probed on loopback.
 *   PHP_FPM_PING_PATH      default /fpm-ping
 *   PHP_FPM_PING_RESPONSE  default pong
 *
 * The whole probe, connect to exit, is bounded by TIMEOUT_MS: poll deadlines for the
 * sockets, and a SIGALRM backstop for getaddrinfo, which cannot be interrupted by a
 * deadline. Buffers are fixed-size; the only heap use is inside getaddrinfo.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define TIMEOUT_MS 2000
#define MAX_PATH_LEN 4096
#define MAX_BODY 65536
#define MAX_CANDIDATES 2

#define FCGI_VERSION 1
#define FCGI_BEGIN_REQUEST 1
#define FCGI_END_REQUEST 3
#define FCGI_PARAMS 4
#define FCGI_STDIN 5
#define FCGI_STDOUT 6
#define FCGI_RESPONDER 1
#define FCGI_REQUEST_ID 1

static struct timespec started;
static char timeout_message[320];

static long elapsed_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)(now.tv_sec - started.tv_sec) * 1000L + (now.tv_nsec - started.tv_nsec) / 1000000L;
}

static void on_alarm(int signo)
{
    (void)signo;
    ssize_t written = write(STDERR_FILENO, timeout_message, strlen(timeout_message));
    (void)written;
    _exit(1);
}

static int remaining_ms(void)
{
    long left = TIMEOUT_MS - elapsed_ms();
    return left > 0 ? (int)left : 0;
}

static int wait_for(int fd, short events)
{
    struct pollfd pfd = {.fd = fd, .events = events};
    for (;;) {
        int left = remaining_ms();
        if (left == 0) {
            return -1;
        }
        int rc = poll(&pfd, 1, left);
        if (rc > 0) {
            return 0;
        }
        if (rc == 0 || errno != EINTR) {
            return -1;
        }
    }
}

static int write_all(int fd, const unsigned char *buf, size_t len)
{
    while (len > 0) {
        if (wait_for(fd, POLLOUT) != 0) {
            return -1;
        }
        ssize_t n = send(fd, buf, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                continue;
            }
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static int read_all(int fd, unsigned char *buf, size_t len)
{
    while (len > 0) {
        if (wait_for(fd, POLLIN) != 0) {
            return -1;
        }
        ssize_t n = recv(fd, buf, len, 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static int skip_bytes(int fd, size_t len)
{
    unsigned char scratch[512];
    while (len > 0) {
        size_t chunk = len < sizeof scratch ? len : sizeof scratch;
        if (read_all(fd, scratch, chunk) != 0) {
            return -1;
        }
        len -= chunk;
    }
    return 0;
}

static int finish_connect(int fd)
{
    int err = 0;
    socklen_t len = sizeof err;
    if (wait_for(fd, POLLOUT) != 0) {
        return -1;
    }
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
        return -1;
    }
    return 0;
}

static int connect_unix(const char *path)
{
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof addr.sun_path) {
        return -1;
    }
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0 && (errno != EINPROGRESS || finish_connect(fd) != 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_tcp(const char *host, const char *port)
{
    struct addrinfo hints = {.ai_socktype = SOCK_STREAM, .ai_flags = AI_NUMERICSERV};
    struct addrinfo *list = NULL;
    if (getaddrinfo(host, port, &hints, &list) != 0) {
        return -1;
    }
    int fd = -1;
    for (const struct addrinfo *ai = list; ai != NULL && fd < 0; ai = ai->ai_next) {
        int candidate = socket(ai->ai_family, ai->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, ai->ai_protocol);
        if (candidate < 0) {
            continue;
        }
        if (connect(candidate, ai->ai_addr, ai->ai_addrlen) == 0 || (errno == EINPROGRESS && finish_connect(candidate) == 0)) {
            fd = candidate;
        } else {
            close(candidate);
        }
    }
    freeaddrinfo(list);
    return fd;
}

/* The listen value split into connect targets. Returns the connected fd, or -1. */
static int connect_listen(const char *listen_spec)
{
    if (strncmp(listen_spec, "unix:", 5) == 0) {
        return connect_unix(listen_spec + 5);
    }
    if (listen_spec[0] == '/') {
        return connect_unix(listen_spec);
    }

    char host[256];
    const char *port;
    const char *candidates[MAX_CANDIDATES] = {NULL, NULL};

    if (listen_spec[0] == '[') {
        const char *close_bracket = strchr(listen_spec, ']');
        if (close_bracket == NULL || close_bracket[1] != ':' || (size_t)(close_bracket - listen_spec) >= sizeof host) {
            return -1;
        }
        memcpy(host, listen_spec + 1, (size_t)(close_bracket - listen_spec - 1));
        host[close_bracket - listen_spec - 1] = '\0';
        port = close_bracket + 2;
    } else if (listen_spec[strspn(listen_spec, "0123456789")] == '\0') {
        /* a bare port listens on every address, v6 and v4-mapped */
        strcpy(host, "::");
        port = listen_spec;
    } else {
        const char *colon = strrchr(listen_spec, ':');
        if (colon == NULL || (size_t)(colon - listen_spec) >= sizeof host) {
            return -1;
        }
        memcpy(host, listen_spec, (size_t)(colon - listen_spec));
        host[colon - listen_spec] = '\0';
        port = colon + 1;
    }
    if (port[0] == '\0' || port[strspn(port, "0123456789")] != '\0') {
        return -1;
    }

    /* A wildcard is a bind address, not a connect address. */
    if (strcmp(host, "0.0.0.0") == 0) {
        candidates[0] = "127.0.0.1";
    } else if (strcmp(host, "::") == 0) {
        candidates[0] = "127.0.0.1";
        candidates[1] = "::1";
    } else {
        candidates[0] = host;
    }
    for (int i = 0; i < MAX_CANDIDATES && candidates[i] != NULL; i++) {
        int fd = connect_tcp(candidates[i], port);
        if (fd >= 0) {
            return fd;
        }
    }
    return -1;
}

static size_t put_length(unsigned char *out, size_t len)
{
    if (len < 128) {
        out[0] = (unsigned char)len;
        return 1;
    }
    out[0] = (unsigned char)(0x80 | (len >> 24));
    out[1] = (unsigned char)(len >> 16);
    out[2] = (unsigned char)(len >> 8);
    out[3] = (unsigned char)len;
    return 4;
}

static size_t put_pair(unsigned char *out, const char *name, const char *value)
{
    size_t name_len = strlen(name);
    size_t value_len = strlen(value);
    size_t at = put_length(out, name_len);
    at += put_length(out + at, value_len);
    memcpy(out + at, name, name_len);
    at += name_len;
    memcpy(out + at, value, value_len);
    return at + value_len;
}

static size_t put_header(unsigned char *out, unsigned type, size_t content_len)
{
    out[0] = FCGI_VERSION;
    out[1] = (unsigned char)type;
    out[2] = 0;
    out[3] = FCGI_REQUEST_ID;
    out[4] = (unsigned char)(content_len >> 8);
    out[5] = (unsigned char)content_len;
    out[6] = 0;
    out[7] = 0;
    return 8;
}

/* BEGIN_REQUEST, one PARAMS record plus its empty terminator, an empty STDIN. */
static size_t build_request(unsigned char *out, const char *ping_path)
{
    size_t at = put_header(out, FCGI_BEGIN_REQUEST, 8);
    memset(out + at, 0, 8);
    out[at + 1] = FCGI_RESPONDER;
    at += 8;

    unsigned char *params_header = out + at;
    at += 8;
    size_t params_len = put_pair(out + at, "SCRIPT_NAME", ping_path);
    params_len += put_pair(out + at + params_len, "SCRIPT_FILENAME", ping_path);
    params_len += put_pair(out + at + params_len, "REQUEST_METHOD", "GET");
    put_header(params_header, FCGI_PARAMS, params_len);
    at += params_len;

    at += put_header(out + at, FCGI_PARAMS, 0);
    at += put_header(out + at, FCGI_STDIN, 0);
    return at;
}

/* Reads records until END_REQUEST. Keeps up to MAX_BODY bytes of STDOUT; the rest is discarded. */
static int read_response(int fd, unsigned char *body, size_t *body_len)
{
    *body_len = 0;
    for (;;) {
        unsigned char header[8];
        if (read_all(fd, header, sizeof header) != 0) {
            return -1;
        }
        if (header[0] != FCGI_VERSION) {
            return -1;
        }
        size_t content_len = ((size_t)header[4] << 8) | header[5];
        size_t padding_len = header[6];
        unsigned type = header[1];

        if (type == FCGI_STDOUT) {
            size_t keep = MAX_BODY - *body_len;
            if (keep > content_len) {
                keep = content_len;
            }
            if (read_all(fd, body + *body_len, keep) != 0) {
                return -1;
            }
            *body_len += keep;
            if (skip_bytes(fd, content_len - keep + padding_len) != 0) {
                return -1;
            }
        } else {
            if (skip_bytes(fd, content_len + padding_len) != 0) {
                return -1;
            }
            if (type == FCGI_END_REQUEST) {
                return 0;
            }
        }
    }
}

static const char *env_or(const char *name, const char *fallback)
{
    const char *value = getenv(name);
    return value != NULL && value[0] != '\0' ? value : fallback;
}

int main(void)
{
    clock_gettime(CLOCK_MONOTONIC, &started);

    const char *listen_spec = env_or("PHP_FPM_LISTEN", "127.0.0.1:9000");
    const char *ping_path = env_or("PHP_FPM_PING_PATH", "/fpm-ping");
    const char *expect = env_or("PHP_FPM_PING_RESPONSE", "pong");

    if (strlen(ping_path) > MAX_PATH_LEN) {
        fprintf(stderr, "PHP_FPM_PING_PATH is longer than %d bytes\n", MAX_PATH_LEN);
        return 1;
    }

    snprintf(timeout_message, sizeof timeout_message, "fpm did not answer on %.200s\n", listen_spec);
    struct sigaction on_timeout = {.sa_handler = on_alarm};
    sigaction(SIGALRM, &on_timeout, NULL);
    alarm((TIMEOUT_MS + 999) / 1000);

    int fd = connect_listen(listen_spec);
    if (fd < 0) {
        fprintf(stderr, "fpm did not answer on %s\n", listen_spec);
        return 1;
    }

    unsigned char request[2 * MAX_PATH_LEN + 256];
    size_t request_len = build_request(request, ping_path);
    static unsigned char body[MAX_BODY];
    size_t body_len;
    if (write_all(fd, request, request_len) != 0 || read_response(fd, body, &body_len) != 0) {
        fprintf(stderr, "fpm did not answer on %s\n", listen_spec);
        close(fd);
        return 1;
    }
    close(fd);
    alarm(0);

    if (memmem(body, body_len, expect, strlen(expect)) == NULL) {
        size_t shown = body_len < 200 ? body_len : 200;
        for (size_t i = 0; i < shown; i++) {
            if (body[i] < ' ' || body[i] > '~') {
                body[i] = ' ';
            }
        }
        fprintf(stderr, "unexpected ping response: %.*s\n", (int)shown, body);
        return 1;
    }
    return 0;
}
