# Argon2

Official PHC reference implementation, tag `20190702` (Argon2 v1.3), vendored from https://github.com/P-H-C/phc-winner-argon2. Files and original LICENSE are retained unchanged. Only the reference CPU implementation is compiled, with `ARGON2_NO_THREADS`; no runtime installation or download is needed.

Application parameters: Argon2id, 19,456 KiB memory, 2 iterations, parallelism 1, 16-byte random salt, 32-byte output. Parameters are persisted and bounded during decode. AES-GCM is provided by Apple's CryptoKit.
