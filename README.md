# macman release installers

This repository hosts the public installer entrypoints for `macmand` and `macman`.

## Install

```bash
curl -fsSL https://arbin-com.github.io/macman-release/install-macmand.sh | bash
curl -fsSL https://arbin-com.github.io/macman-release/install-macman.sh | bash
```

## Release layout

The installers expect:

- `latest` to contain the newest released version string
- `<version>/manifest.json` to describe the platform assets
- private GitHub release assets for the actual binaries
- the daemon bundle to unpack `web/dist` beside `macmand`

The installer scripts support:

- `GH_TOKEN` / `GITHUB_TOKEN` for PAT auth
- cached GitHub App auth in `~/.config/macman/github-app-auth.json`
- interactive browser login when no token is available

## Files

- `install-common.sh`
- `install-macmand.sh`
- `install-macman.sh`
