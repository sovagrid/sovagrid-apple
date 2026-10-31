/* SPDX-License-Identifier: AGPL-3.0-only
 * SovaGrid — Copyright (C) 2026 Jigokuraku01
 * Additional attribution terms: see ../../ATTRIBUTION.md. */
#ifndef SOVAGRID_OPENSSH_DECRYPT_H
#define SOVAGRID_OPENSSH_DECRYPT_H

#include <stddef.h>
#include <stdint.h>

/* The caller checks the OpenSSH key envelope, KDF options and public key.
 * The derived AES key and IV are cleared before return. */
int SovaGridDecryptOpenSSHAES256CTR(const uint8_t *encrypted, size_t length,
                                    const uint8_t *salt, size_t salt_length,
                                    uint32_t rounds, const uint8_t *passphrase,
                                    size_t passphrase_length, uint8_t *plaintext);

#endif
