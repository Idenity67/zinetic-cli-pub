# Zinetic CLI Distribution

Public distribution repository for the released `zin` CLI installer and release checksums.

## Install

Install `cosign` first so the installer can verify the signed release checksums.

```sh
curl -fsSL https://cli.zinetic.net/install.sh | sh
```

Enterprise installs can make the requirement explicit:

```sh
curl -fsSL https://cli.zinetic.net/install.sh | ZIN_REQUIRE_SIGSTORE=1 sh
```

The installer verifies SHA-256 checksums for every downloaded archive and verifies the Sigstore bundle by default. If `cosign` is missing, installation fails. To explicitly accept an unverified install in a controlled break-glass scenario:

```sh
curl -fsSL https://cli.zinetic.net/install.sh | ZIN_SKIP_SIGSTORE=1 sh
```

## Version Pinning

```sh
curl -fsSL https://cli.zinetic.net/install.sh | ZIN_VERSION=v0.2.2 sh
```

## Security

Do not commit access tokens, tenant secrets, private keys, `.env` files, or GitHub credentials. Release artifacts must be signed and checksummed by the private CLI source release workflow before they are mirrored here.
