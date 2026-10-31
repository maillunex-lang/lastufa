# Signing keys

`dev_private.pem` is a **development-only** RSA key. Its public half is
`config/trusted_keys/dev_ashenfall.pem`, which the game trusts **only in debug
builds** (files named `dev_*.pem` are ignored by release builds).

For release:
1. Generate a production key offline: `openssl genrsa -out release_private.pem 3072`.
2. Never commit it. Keep it in the release pipeline's secret storage.
3. Put the public key into `config/trusted_keys/release_ashenfall.pem`.
4. Sign packages with `python3 tools/afpkg.py build ... --key release_private.pem`.
