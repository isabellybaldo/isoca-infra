# isoca-infra

How one small VPS is set up and how a frozen static site gets onto it. The box serves
`radar.isoca.space`, a snapshot of the [isoca-radar](https://github.com/isabellybaldo/isoca-radar)
dashboard, and every deploy comes from GitHub Actions. Setup scripts, edge config, runbooks and tests
live here; the box's address and keys do not.

```
GitHub Actions
     |  ssh, one forced command (upload a tar, nothing else)
     v
/srv/sites/<site>/current  <--  nginx  <--  Traefik  <--  visitors
                                                (TLS)      radar.isoca.space

isoca.space  --302-->  github.io (portfolio)
```

## Layout

```
box/         scripts that set up the VPS (users, ssh, firewall, deploy command)
edge/        nginx and Traefik config
runbooks/    the steps a human runs, in order
tests/       checks that run in CI and locally
.github/     CI and the deploy workflows
```

## Runbooks

1. [Box setup](runbooks/01-box-setup.md): bring a fresh VPS to the point where it can serve a site.
2. [Cut-over](runbooks/02-cut-over.md): move traffic from the old box to the new one.

## Not in this repo

The repo is public, so these stay out of it. `tests/no-secrets.sh` and gitleaks check that in CI.

- The box's IP address and SSH port: they sit in a git-ignored `local.env` (see `local.env.example`).
- SSH keys and fingerprints: the deploy key lives in GitHub Actions secrets, the others on my machine.
- Account names beyond the two roles, `deploy` and `claude`.

## Checks

```
bash tests/no-secrets.sh
shellcheck box/* tests/*.sh
```

## License

MIT.
