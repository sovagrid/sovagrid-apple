/* SPDX-License-Identifier: AGPL-3.0-only
 * SovaGrid — Copyright (C) 2026 Jigokuraku01
 * Additional attribution terms: see ../../ATTRIBUTION.md.
 * Adapt OpenSSH's SHA-512 call to Apple CommonCrypto. */
#ifndef SOVAGRID_OPENSSH_CRYPTO_API_H
#define SOVAGRID_OPENSSH_CRYPTO_API_H

#include <CommonCrypto/CommonDigest.h>
#include <limits.h>

#define crypto_hash_sha512_BYTES CC_SHA512_DIGEST_LENGTH

static inline int crypto_hash_sha512(unsigned char *output, const void *input,
                                      unsigned long long length) {
    if (length > UINT_MAX) return -1;
    return CC_SHA512(input, (CC_LONG)length, output) == NULL ? -1 : 0;
}

#endif
