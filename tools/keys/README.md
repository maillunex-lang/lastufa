# Signing keys

- `dev_private.pem` — **development-only** key, public in this repository. Its public half
  `config/trusted_keys/dev_ashenfall.pem` is trusted only by debug builds and **never for game code**.
  Use it for local content/mod packages: `python3 tools/afpkg.py build ... ` (default key).
- `config/trusted_keys/release_ashenfall.pem` — public half of the **release** key. The private key
  lives only in the GitHub secret `AF_SIGNING_KEY` (and the owner's offline backup). It signs the
  game-code pack and published content in `.github/workflows/publish-updates.yml`.

Never commit private release keys or keystores (`.gitignore` blocks the usual names).
Losing the release key means installed games can no longer accept updates until a new APK
with a new public key is installed.
