# Zinetic CLI Distribution

Public distribution repository for the released `zin` CLI installer and release checksums.

## Install

```sh
curl -fsSL https://cli.zinetic.net/install.sh | sh
```

To require Sigstore verification:

```sh
curl -fsSL https://cli.zinetic.net/install.sh | ZIN_REQUIRE_SIGSTORE=1 sh
```

The installer verifies SHA-256 checksums for every downloaded archive. When `cosign` is installed, the installer also verifies the Sigstore bundle and refuses unverified releases.

## Version Pinning

```sh
curl -fsSL https://cli.zinetic.net/install.sh | ZIN_VERSION=v0.2.2 sh
```

## Security

Do not commit access tokens, tenant secrets, private keys, `.env` files, or GitHub credentials. Release artifacts must be signed and checksummed by the private CLI source release workflow before they are mirrored here.
