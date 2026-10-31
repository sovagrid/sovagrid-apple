# OpenSSH key decryption source

`bcrypt_pbkdf.c`, `blowfish.c` and `blf.h` are copied unchanged from
[`openssh/openssh-portable`](https://github.com/openssh/openssh-portable/tree/1fbdcb402516aacce59b4cc7b7d98f06820a1e44/openbsd-compat),
commit `1fbdcb402516aacce59b4cc7b7d98f06820a1e44`.
Their permissive original copyright notices remain in those files.
`includes.h` and `crypto_api.h` provide the Apple type, memory clearing and
CommonCrypto SHA-512 calls expected by the unchanged source. The small
`SovaGridOpenSSHDecrypt.c` bridge uses Apple CommonCrypto AES-256-CTR.

Only OpenSSH Ed25519 keys using `aes256-ctr` and `bcrypt` are accepted.
The parser validates the outer public key against the decrypted seed and
rejects unsupported ciphers or KDFs. The passphrase is supplied only during
import; the existing 32-byte seed is stored in ThisDeviceOnly Keychain.
