# macman release installers

This repository hosts the public installer entrypoints for `macmand` and `macman`.

GitHub Pages: https://arbin-com.github.io/macman-release/

## Install

```bash
curl -fsSL https://arbin-com.github.io/macman-release/install-macmand.sh | bash
curl -fsSL https://arbin-com.github.io/macman-release/install-macman.sh | bash
```

## Release lookup

The installers expect:

- the newest release tag from the private `Arbin-com/macman` repo
- private GitHub release assets for the actual binaries
- the daemon bundle to unpack `web/dist` beside `macmand`

The installer scripts support:

- `GH_TOKEN` / `GITHUB_TOKEN` for PAT auth
- cached GitHub App auth in `~/.config/macman/github-app-auth.json`
- interactive browser login when no token is available
- `newest` as the default release selector, with `VERSION` override support

## Files

- `install-common.sh`
- `install-macmand.sh`
- `install-macman.sh`
