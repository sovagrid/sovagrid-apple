/* SPDX-License-Identifier: AGPL-3.0-only
 * SovaGrid — Copyright (C) 2026 Jigokuraku01
 * Additional attribution terms: see ../../ATTRIBUTION.md.
 * SovaGrid portability glue for pinned OpenSSH bcrypt_pbkdf and Blowfish. */
#ifndef SOVAGRID_OPENSSH_INCLUDES_H
#define SOVAGRID_OPENSSH_INCLUDES_H

#define __STDC_WANT_LIB_EXT1__ 1
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define HAVE_STDLIB_H 1

static inline void sovagrid_explicit_bzero(void *value, size_t length) {
    if (value != NULL && length != 0) {
        (void)memset_s(value, length, 0, length);
    }
}

static inline void sovagrid_freezero(void *value, size_t length) {
    sovagrid_explicit_bzero(value, length);
    free(value);
}

#define explicit_bzero sovagrid_explicit_bzero
#define freezero sovagrid_freezero

#include "blf.h"

#endif
