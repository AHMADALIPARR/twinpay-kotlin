/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Ahmad Parr
 */

/* twinpay WORM port driver.
 *
 * Fresh code written for twinpay. It links the vendored finance-twin WORM
 * commit routine (c_src/worm_commit.c and c_src/worm_block.h, copied
 * verbatim with license headers intact, never modified) and exposes it to
 * Erlang over a {packet,4} framed port.
 *
 * Protocol (all integers big-endian):
 *   'C' + payload (1..4096 bytes)  -> commit one WORM block
 *       reply 'O' + index:64 + hash:64   (hash = 64-byte current_hash field)
 *       reply 'E' + code:32signed        (commit_to_worm_storage error)
 *   'V'                            -> verify the whole chain
 *       reply 'O' + count:64
 *       reply 'E' + bad_index:64
 *   'N'                            -> block count
 *       reply 'O' + count:64
 *
 * Hash note: with USE_OPENSSL the vendored routine stores the raw 32-byte
 * SHA-256 digest in the first 32 bytes of current_hash (remaining 32 bytes
 * zeroed by our memset). Verification recomputes the identical digest, so
 * the chain is self-consistent. Without OpenSSL the vendored deterministic
 * placeholder hash is used instead; the Makefile prefers OpenSSL.
 *
 * NOTE: worm_commit.c also defines chisel_hardware_seal_ffi, which writes
 * to a hardcoded MMIO address. It is dead code here and is never called.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include "worm_block.h"

#ifdef USE_OPENSSL
#include <openssl/sha.h>
#endif

static int g_fd = -1;
static uint64_t g_count = 0;
static unsigned char g_prev_hash[WORM_HASH_SIZE];

static int read_exact(int fd, unsigned char *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r == 0) return -1; /* EOF */
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        got += (size_t)r;
    }
    return 0;
}

static int write_exact(int fd, const unsigned char *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = write(fd, buf + done, n - done);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return -1;
        }
        done += (size_t)r;
    }
    return 0;
}

static void put_u32be(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

static void put_u64be(unsigned char *p, uint64_t v) {
    put_u32be(p, (uint32_t)(v >> 32));
    put_u32be(p + 4, (uint32_t)v);
}

static uint32_t get_u32be(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* Send one framed reply: 4-byte length prefix + body. */
static int reply(const unsigned char *body, uint32_t len) {
    unsigned char hdr[4];
    put_u32be(hdr, len);
    if (write_exact(STDOUT_FILENO, hdr, 4) < 0) return -1;
    return write_exact(STDOUT_FILENO, body, len);
}

static int reply_ok_u64(uint64_t v) {
    unsigned char b[1 + 8];
    b[0] = 'O';
    put_u64be(b + 1, v);
    return reply(b, sizeof b);
}

static int reply_err_s32(int32_t v) {
    unsigned char b[1 + 4];
    b[0] = 'E';
    put_u32be(b + 1, (uint32_t)v);
    return reply(b, sizeof b);
}

static int do_commit(const unsigned char *payload, uint32_t plen) {
    WormBlock blk;
    unsigned char out[1 + 8 + WORM_HASH_SIZE];

    if (plen == 0 || plen > WORM_PAYLOAD_SIZE) {
        return reply_err_s32(-100);
    }
    memset(&blk, 0, sizeof blk);
    memcpy(blk.magic, "WORM", WORM_MAGIC_SIZE);
    memcpy(blk.prev_hash, g_prev_hash, WORM_HASH_SIZE);
    blk.record_count = (uint32_t)g_count;
    memcpy(blk.payload, payload, plen);

    int rc = commit_to_worm_storage(g_fd, &blk);
    if (rc != 0) {
        return reply_err_s32((int32_t)rc);
    }
    memcpy(g_prev_hash, blk.current_hash, WORM_HASH_SIZE);
    out[0] = 'O';
    put_u64be(out + 1, g_count);
    memcpy(out + 1 + 8, blk.current_hash, WORM_HASH_SIZE);
    g_count++;
    return reply(out, sizeof out);
}

#ifdef USE_OPENSSL
static int recompute_ok(const WormBlock *blk) {
    unsigned char digest[32];
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    SHA256_Update(&ctx, blk->prev_hash, WORM_HASH_SIZE);
    SHA256_Update(&ctx, blk->payload, WORM_PAYLOAD_SIZE);
    SHA256_Final(digest, &ctx);
    return memcmp(digest, blk->current_hash, 32) == 0;
}
#endif

static int do_verify(void) {
    unsigned char expected_prev[WORM_HASH_SIZE];
    uint64_t i;

    memset(expected_prev, '0', WORM_HASH_SIZE);
    if (lseek(g_fd, 0, SEEK_SET) == (off_t)-1) {
        return reply_err_s32(WORM_ERR_SEEK);
    }
    for (i = 0; i < g_count; i++) {
        WormBlock blk;
        unsigned char ebuf[1 + 8];
        if (read_exact(g_fd, (unsigned char *)&blk, sizeof blk) < 0) {
            ebuf[0] = 'E';
            put_u64be(ebuf + 1, i);
            return reply(ebuf, sizeof ebuf);
        }
        if (memcmp(blk.magic, "WORM", WORM_MAGIC_SIZE) != 0 ||
            memcmp(blk.prev_hash, expected_prev, WORM_HASH_SIZE) != 0) {
            ebuf[0] = 'E';
            put_u64be(ebuf + 1, i);
            return reply(ebuf, sizeof ebuf);
        }
#ifdef USE_OPENSSL
        if (!recompute_ok(&blk)) {
            ebuf[0] = 'E';
            put_u64be(ebuf + 1, i);
            return reply(ebuf, sizeof ebuf);
        }
#else
        /* Without OpenSSL the vendored placeholder hash cannot be
         * recomputed here (it is static inside worm_commit.c); linkage
         * of prev_hash is still checked. */
#endif
        memcpy(expected_prev, blk.current_hash, WORM_HASH_SIZE);
    }
    return reply_ok_u64(g_count);
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "worm.dat";

    g_fd = open(path, O_RDWR | O_CREAT, 0644);
    if (g_fd < 0) return 1;

    {
        off_t sz = lseek(g_fd, 0, SEEK_END);
        if (sz < 0) return 1;
        g_count = (uint64_t)sz / (uint64_t)sizeof(WormBlock);
        if (g_count > 0) {
            WormBlock last;
            off_t off = (off_t)((g_count - 1) * sizeof(WormBlock));
            if (lseek(g_fd, off, SEEK_SET) != off) return 1;
            if (read_exact(g_fd, (unsigned char *)&last, sizeof last) < 0) return 1;
            memcpy(g_prev_hash, last.current_hash, WORM_HASH_SIZE);
        } else {
            memset(g_prev_hash, '0', WORM_HASH_SIZE);
        }
    }

    for (;;) {
        unsigned char hdr[4];
        uint32_t len;
        unsigned char *msg;

        if (read_exact(STDIN_FILENO, hdr, 4) < 0) break; /* EOF -> exit */
        len = get_u32be(hdr);
        if (len == 0 || len > (1 + WORM_PAYLOAD_SIZE)) {
            /* Drain nothing; protocol violation -> error reply and continue. */
            reply_err_s32(-101);
            continue;
        }
        msg = (unsigned char *)malloc(len);
        if (!msg) return 1;
        if (read_exact(STDIN_FILENO, msg, len) < 0) {
            free(msg);
            break;
        }
        switch (msg[0]) {
        case 'C':
            do_commit(msg + 1, len - 1);
            break;
        case 'V':
            do_verify();
            break;
        case 'N':
            reply_ok_u64(g_count);
            break;
        default:
            reply_err_s32(-102);
            break;
        }
        free(msg);
    }
    return 0;
}
