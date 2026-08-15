# Image provenance and verification

Bootsy publishes immutable `sha-<commit>` tags alongside `latest`, and embeds
the full Git revision in `/usr/lib/bootsy-release`. Prefer the immutable tag in
production and compare it with `bootsy-status` after an update.

The build workflow signs every pushed digest with a keyless Sigstore signature
using GitHub Actions OIDC; no private signing key is stored. Verify an immutable
digest with `cosign verify`, pinning both the GitHub Actions issuer and the exact
certificate identity reported by an initial manual verification. Host-side
enforcement should only be enabled after that identity is pinned and tested;
otherwise a syntactically valid but unrelated signature could be accepted.
