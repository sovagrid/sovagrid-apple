/* SPDX-License-Identifier: AGPL-3.0-only
 * SovaGrid — Copyright (C) 2026 Jigokuraku01
 * Additional attribution terms: see ../../ATTRIBUTION.md. */
#define __STDC_WANT_LIB_EXT1__ 1
#include "SovaGridOpenSSHDecrypt.h"
#include <CommonCrypto/CommonCryptor.h>
#include <string.h>

int bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt,
                 size_t saltlen, uint8_t *key, size_t keylen, unsigned int rounds);

int SovaGridDecryptOpenSSHAES256CTR(const uint8_t *encrypted, size_t length,
                                    const uint8_t *salt, size_t salt_length,
                                    uint32_t rounds, const uint8_t *passphrase,
                                    size_t passphrase_length, uint8_t *plaintext) {
    if (encrypted == NULL || salt == NULL || passphrase == NULL || plaintext == NULL ||
        length == 0 || length > 512 || length % 16 != 0 ||
        salt_length < 16 || salt_length > 64 ||
        passphrase_length == 0 || passphrase_length > 1024 ||
        rounds == 0 || rounds > 256) return -1;

    uint8_t key_and_iv[48] = {0};
    CCCryptorRef cryptor = NULL;
    int result = -1;
    if (bcrypt_pbkdf((const char *)passphrase, passphrase_length, salt,
                     salt_length, key_and_iv, sizeof(key_and_iv), rounds) != 0) goto done;
    if (CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES,
                               ccNoPadding, key_and_iv + 32, key_and_iv, 32,
                               NULL, 0, 0, kCCModeOptionCTR_BE, &cryptor) != kCCSuccess) goto done;
    size_t written = 0;
    size_t final_written = 0;
    if (CCCryptorUpdate(cryptor, encrypted, length, plaintext, length,
                       &written) != kCCSuccess) goto done;
    if (CCCryptorFinal(cryptor, plaintext + written, length - written,
                      &final_written) != kCCSuccess || written + final_written != length) goto done;
    result = 0;

done:
    if (cryptor != NULL) CCCryptorRelease(cryptor);
    (void)memset_s(key_and_iv, sizeof(key_and_iv), 0, sizeof(key_and_iv));
    if (result != 0) (void)memset_s(plaintext, length, 0, length);
    return result;
}
