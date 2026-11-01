# isoca-infra

How one small VPS is set up and how a frozen static site gets onto it. The box serves
`radar.isoca.space`, a snapshot of the [isoca-radar](https://github.com/isabellybaldo/isoca-radar)
dashboard, and `play.isoca.space`, a private game site from
[isoca-play](https://github.com/isabellybaldo/isoca-play). Every deploy comes from GitHub Actions. The deploy
command, edge config, runbooks and tests live here (the rest of the setup is runbook steps); the box's address
and keys do not.

```
GitHub Actions
     |  ssh, one forced command (upload a tar, roll back, or edge-config: nothing else)
     v
/srv/sites/<site>/current  <--  nginx  <--  Traefik  <--  visitors
                                                (TLS)      radar.isoca.space

isoca.space  --302-->  github.io (portfolio)

GitHub Actions (isoca-play)
     |  ssh, a second key: "release play sha256:..." or "rollback play", nothing else
     v
/srv/play/state/desired-image
     |  systemd path unit and a one-minute timer, as root
     v
play-apply: pull, recreate, wait for healthy, or go back to the old digest
     v
play container  <--  Traefik  <--  visitors
(no published ports,   (TLS)       play.isoca.space
 no internet)
```

## Layout

```
box/         site-deploy, the forced command behind the deploy keys; play-apply and its systemd units
edge/        nginx and Traefik config
play/        the compose file for the play container
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
for t in tests/*.test.sh; do bash "$t"; done
shellcheck box/site-deploy box/play-apply tests/*.sh
```

## AI disclosure

This project was built with Claude Code, Anthropic's AI coding agent, which wrote most of the code, tests, and docs. I chose what to build, made the design calls and approved the results, and I'm responsible for what's here.

## License

MIT.
