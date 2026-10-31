# Runbook 1: set up the new box

Owner-run. Every step is one command block, then `→ expected:`, then `if not:`. **STOP** means: do not go on until it is fixed.
Values come from `local.env` (`VPS_IP`, `SSH_PORT`, `ADMIN`). On the box there is no `local.env`: step 14 types them in.

Where a step runs:

- **PC PowerShell**, **PC Git Bash**: your Windows machine. Git Bash blocks use Windows OpenSSH (it talks to the ssh-agent from step 8).
- **VPS root**: window A, the root login of step 13. Keep it open to the end. If it is lost after step 25, log in as `$ADMIN` on the new port, run `sudo -i`, then step 14 again.
- **Hostinger browser**: the Hostinger panel.

Way back from any lockout: the Hostinger panel's browser console takes the root password and works whatever sshd and the firewalls say.
fail2ban counts refused logins. If it bans you: Hostinger panel console, `fail2ban-client unban --all`.
After step 8, use only Git Bash windows opened after that step.

Before you start: have the Hostinger panel and the new box's root password at hand.

## Before anything goes public

### 1. PC PowerShell: is the backup drive there, and is the backup in it?

```powershell
(Get-ChildItem E:\isoca-radar-backup -Recurse -File | Measure-Object Length -Sum).Sum / 1GB
```

→ expected: a number of about 28 (gigabytes).
if not: **STOP.** An error, or a number far below 28: plug the drive in or find the right folder. Step 3 deletes the old box for good.

### 2. PC Git Bash: the new box's IP is not the old box's

```bash
read -r -p "old box IP: " OLD; read -r -p "new box IP: " NEW; [ -n "$OLD" ] && [ -n "$NEW" ] && [ "$OLD" != "$NEW" ] && echo different || echo SAME-OR-EMPTY
```

→ expected: `different`
if not: **STOP.** Read both IPs again in the Hostinger panel (the old one is in isoca-radar's git history). Same IP means you are looking at one box.

### 3. Hostinger browser: delete the old box

```text
Hostinger panel > VPS > the OLD server > Settings > Delete / Cancel
(the backup in E:\isoca-radar-backup was verified; step 1 showed the drive is there)
```

→ expected: the VPS list shows only the new server.
if not: do not touch the new server. Find the old server's entry by the IP you typed in step 2.

### 4. PC Git Bash: push isoca-infra's main (step 37 clones it)

```bash
cd ~/PycharmProjects/isoca-infra && MSYS_NO_PATHCONV=1 docker run --rm -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' -v "$(cygpath -m "$PWD"):/scan:ro" zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f git /scan --redact --log-opts="--all" && git push origin main && git status -sb | head -1 && gh repo view isabellybaldo/isoca-infra --json visibility -q .visibility
```

→ expected: first `no leaks found` (gitleaks over the whole local history; the push only runs after it), then `## main...origin/main` then `PUBLIC`. The repo is already public and empty, so this push publishes it at once. The first push also starts the `edge-config` workflow: it goes red (the secrets do not exist yet) and creates the `production` environment; step 46 sets that environment's branch rule. The `ci` workflow must go green; `edge-config` red is expected.
if not: `leaks found` -> **STOP**, do not push: nothing has been published yet. A push error: fix it first (`gh auth status`). `PRIVATE` -> **STOP** and make the repo public first; this runbook assumes it is public.

### 5. PC Git Bash: a full mirror clone of isoca-radar at a temp path (all branches, tags, PR refs)

```bash
T=$(mktemp -d) && git clone --mirror https://github.com/isabellybaldo/isoca-radar "$T/radar.git" && git -C "$T/radar.git" for-each-ref | wc -l
```

→ expected: a number greater than 0 (every ref in the mirror). Stay in this window: `$T` is used in steps 6 and 7.
if not: sign in with `gh auth login` and retry. `$T` empty after a reopen -> run this step again.

### 6. PC Git Bash: gitleaks, pinned image, whole history; read every finding

```bash
R=$(mktemp -d) && MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -m "$T"):/scan:ro" -v "$(cygpath -m "$R"):/out" zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f git /scan/radar.git --log-opts="--all" --report-format json --report-path /out/report.json; echo "findings: $(grep -c '"RuleID"' "$R/report.json")"; grep -oE '"(RuleID|File|Secret)": ?"[^"]*"' "$R/report.json"
```

→ expected: `N commits scanned` with N > 0, then `leaks found: 4` and `findings: 4`: four `generic-api-key`, three in `docs/superpowers/plans/2026-10-24-old-vps-backup.md` and one in `docs/superpowers/runbooks/old-vps-backup.md`. Read the four `Secret` values: they should be throwaways (for example `POSTGRES_PASSWORD=restore` from a temporary restore container). The report is NOT redacted; step 7 deletes it.
if not: **STOP**, do not flip, on any other count, any other file, or a value that looks real. A real secret: rotate it first, then decide about the history. "dubious ownership" -> add `-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*'` before the image name. Keep this window: `$T` and `$R` are used in step 7.

### 7. PC Git Bash: make isoca-radar public (step 46 needs it: on GitHub Free, environment secrets and branch limits exist only in public repos)

Heads-up: this also publishes the Gmail address on old commits. If that is not acceptable, stop here.

```bash
gh repo edit isabellybaldo/isoca-radar --visibility public --accept-visibility-change-consequences && gh repo view isabellybaldo/isoca-radar --json visibility -q .visibility && rm -rf "$T" "$R"
```

→ expected: `PUBLIC`
if not: read the error (`gh auth status`; you need admin on the repo). Nothing is public until this prints `PUBLIC`.

## Your PC

### 8. PC PowerShell (run as administrator): start the Windows ssh-agent, load your key, give Git Bash a real terminal

```powershell
Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent; ssh-add $env:USERPROFILE\.ssh\id_ed25519; setx MSYS enable_pcon
```

→ expected: `Identity added: ...\id_ed25519` after one passphrase prompt, then `SUCCESS: Specified value was saved.` **Now close every Git Bash window and open new ones for all later steps**: without this setting Windows ssh has no terminal in Git Bash, and `ssh -t`, sudo prompts and passphrase prompts hang.
if not: `No such file` -> you have no owner key yet: `ssh-keygen -t ed25519` (with a passphrase), then repeat. "service cannot be started" -> Windows Settings > Optional features > OpenSSH Client, then repeat.

### 9. PC Git Bash: Windows OpenSSH is the ssh in use, and it sees the agent

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; command -v ssh ssh-add ssh-keygen scp ssh-keyscan; ssh-add -l
```

→ expected: five paths under `/c/Windows/System32/OpenSSH/`, then one `ED25519` line from `ssh-add -l`.
if not: `The agent has no identities` -> repeat step 8. Git's own ssh cannot use the Windows agent, which is why every key-based Git Bash block below puts this folder first on PATH.

### 10. PC Git Bash: `local.env` from the example

```bash
cd ~/PycharmProjects/isoca-infra && cp -n local.env.example local.env && notepad local.env
```

→ expected: Notepad opens. Set `VPS_IP` (the new box), `SSH_PORT` (your choice, 1024-65535, not 22), `ADMIN` (your login name on the box, not root, deploy or claude). Leave the two key paths. Save, close.
if not: `local.env` is git-ignored; never `git add -f` it.

### 11. PC Git Bash: `local.env` is usable (no CR characters, sane values)

```bash
cd ~/PycharmProjects/isoca-infra && [ "$(tr -cd '\r' < local.env | wc -c)" = 0 ] && set -a && . ./local.env && set +a && [[ $VPS_IP =~ ^[0-9]+(\.[0-9]+){3}$ && $VPS_IP != 203.0.113.10 && $SSH_PORT =~ ^[0-9]+$ && $SSH_PORT -gt 1023 && $SSH_PORT -lt 65536 && $ADMIN =~ ^[a-z][a-z0-9_-]{1,31}$ && $ADMIN != root && $ADMIN != deploy && $ADMIN != claude ]] && echo local-env-ok
```

→ expected: `local-env-ok`
if not: open `local.env` again; the example values (the 203.0.113 address) and Windows line endings are the usual causes.

### 12. PC Git Bash: the deploy and claude keys

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && DEPLOY_KEY_PATH=$(cygpath -m "$DEPLOY_KEY_PATH") && CLAUDE_KEY_PATH=$(cygpath -m "$CLAUDE_KEY_PATH") && [ ! -e "$DEPLOY_KEY_PATH" ] && [ ! -e "$CLAUDE_KEY_PATH" ] && ssh-keygen -t ed25519 -N "" -C isoca_deploy -f "$DEPLOY_KEY_PATH" && ssh-keygen -t ed25519 -C isoca_claude -f "$CLAUDE_KEY_PATH" && cat "$DEPLOY_KEY_PATH.pub" "$CLAUDE_KEY_PATH.pub" | cut -c1-40
```

→ expected: no passphrase for `isoca_deploy` (it lives only in GitHub after step 47, and the local copy is deleted in step 48); a passphrase of your choice for `isoca_claude` (step 41 loads it into the agent); then two lines starting `ssh-ed25519 AAAA`.
if not: a key file already exists -> the block refuses on purpose. Look at it; delete it only if it is yours and unused.

## The box

### 13. PC Git Bash: first login as root (this is window A; keep it open to the end)

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -o PubkeyAuthentication=no root@"$VPS_IP"
```

→ expected: a host-key question (answer `yes`; the fingerprint is checked in step 15), the root password from the Hostinger panel, then a `root@...#` prompt.
if not: `Connection refused` -> the box is not up yet (panel: status Running); `Permission denied` -> reset the root password in the panel.

### 14. VPS root: type in the two values (never saved, never committed; repeat in every new VPS window)

```bash
read -r -p "SSH_PORT: " SSH_PORT; read -r -p "ADMIN: " ADMIN; export SSH_PORT ADMIN; [[ $SSH_PORT =~ ^[0-9]+$ && $SSH_PORT -gt 1023 && $SSH_PORT -lt 65536 && $ADMIN =~ ^[a-z][a-z0-9_-]{1,31}$ && $ADMIN != root && $ADMIN != deploy && $ADMIN != claude ]] && echo "vars ok" || echo "BAD VALUES"
```

→ expected: after you type the two values from `local.env`: `vars ok`
if not: `BAD VALUES` -> paste the line again and retype.

### 15. VPS root: check the OS, then the box's own host-key fingerprint. **STOP** unless Ubuntu 26.04 and the fingerprint matches.

```bash
. /etc/os-release && [ "$ID" = ubuntu ] && [ "$VERSION_ID" = "26.04" ] && [ "$(id -u)" = 0 ] && echo "ok: $PRETTY_NAME" || echo "NOT UBUNTU 26.04 AS ROOT: $PRETTY_NAME"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

→ expected: `ok: Ubuntu 26.04...`, then one `256 SHA256:... (ED25519)` line equal to the fingerprint your PC showed in step 13 (scroll up in the PC window).
if not: **STOP.** `NOT UBUNTU`: this runbook is written for Ubuntu 26.04 (socket-activated sshd, sudo-rs, uutils coreutils); reinstall the OS as Ubuntu 26.04 in the Hostinger panel and start again at step 13. A different fingerprint: the first connection did not reach this box; close window A, check the IP in the panel, start again at step 13.

### 16. PC Git Bash (a second window): copy the three public keys to the box

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && D=$(mktemp -d) && cp ~/.ssh/id_ed25519.pub "$D/owner.pub" && cp "$DEPLOY_KEY_PATH.pub" "$D/isoca_deploy.pub" && cp "$CLAUDE_KEY_PATH.pub" "$D/isoca_claude.pub" && scp -o PubkeyAuthentication=no "$D"/*.pub root@"$VPS_IP":/root/ && rm -rf "$D"
```

→ expected: the root password once, then three lines, `isoca_claude.pub`, `isoca_deploy.pub`, `owner.pub` last, each at 100%.
if not: `No such file` -> step 12 (keys) did not run, or your owner key has another name. Only public keys travel; nothing secret.

### 17. VPS root: update the system and install what later steps use

```bash
export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y -o Dpkg::Options::=--force-confold full-upgrade && apt-get -y install git ufw fail2ban python3 python3-systemd unattended-upgrades util-linux tar gzip curl ca-certificates gnupg; [ -f /var/run/reboot-required ] && echo REBOOT-NEEDED || echo no-reboot-needed
```

→ expected: ends with `no-reboot-needed` or `REBOOT-NEEDED`.
if not: `REBOOT-NEEDED` -> run `reboot`, wait a minute, then repeat steps 13 and 14. An apt lock error -> wait two minutes and repeat the block.

### 18. VPS root: the admin user, with sudo and your public key

```bash
adduser --gecos "" "$ADMIN" && usermod -aG sudo "$ADMIN" && install -d -m 700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.ssh" && install -m 600 -o "$ADMIN" -g "$ADMIN" /root/owner.pub "/home/$ADMIN/.ssh/authorized_keys" && id "$ADMIN" && wc -l "/home/$ADMIN/.ssh/authorized_keys"
```

→ expected: a password prompt twice (this is the sudo password; keep it in your password manager; ssh will never accept it), then an `id` line containing `sudo`, then `1 /home/.../authorized_keys`.
if not: `user already exists` -> run `usermod -aG sudo "$ADMIN"` and the two `install` commands only.

### 19. PC Git Bash (a new window): log in as admin on the OLD port with the key. **STOP** if it fails.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p 22 -o PasswordAuthentication=no "$ADMIN@$VPS_IP" 'id -nG; sudo -v && echo sudo-ok'
```

→ expected: no password for the login itself; a group list containing `sudo`; the sudo password prompt; `sudo-ok`.
if not: **STOP**, leave window A open. In window A: `ls -ld /home/$ADMIN /home/$ADMIN/.ssh`, `cat /home/$ADMIN/.ssh/authorized_keys`, `journalctl -u ssh -n 20`. Without this key login, the next steps are not safe.

### 20. VPS root: firewall, with the old and the new SSH port both open

```bash
ufw default deny incoming && ufw default allow outgoing && ufw allow 22/tcp && ufw allow "$SSH_PORT"/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable && ufw status
```

→ expected: `Status: active` and ALLOW rules for 22, your port, 80, 443 (IPv4 and IPv6 lines). Window A stays connected.
if not: `ufw disable`, then repeat. Never enable ufw without the 22 rule while logged in over 22.

### 21. Hostinger browser: the panel firewall must allow the same ports

```text
Hostinger panel > VPS > this server > Security > Firewall
Accept TCP: 22 (temporary), SSH_PORT from local.env, 80, 443.  Activate it / attach it to this VPS.
(no firewall configured in the panel = all ports open = nothing to do; ufw is then the only filter)
```

→ expected: the panel lists those four TCP rules as the active firewall for this VPS (or has no firewall).
if not: **STOP** before step 24. A closed new port locks you out the moment ssh moves.

### 22. VPS root: a throwaway listener on the new port, for 2 minutes (it serves nothing)

```bash
(timeout 120 python3 -c 'import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",int(sys.argv[1]))); s.listen(1); c,_=s.accept(); c.close()' "$SSH_PORT" >/dev/null 2>&1 &); sleep 1; ss -ltn | grep ":$SSH_PORT "
```

→ expected: one `LISTEN` line on `0.0.0.0:<your port>`. Run step 23 within 2 minutes.
if not: nothing listed -> `command -v python3`, repeat. Something else already listens on that port -> pick another in `local.env` and redo step 14.

### 23. PC Git Bash: can the internet reach the new port? **STOP** if not.

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && (timeout 5 bash -c "exec 3<>/dev/tcp/$VPS_IP/$SSH_PORT" && echo open || echo closed)
```

→ expected: `open`
if not: **STOP.** `closed` -> the block is ufw (step 20) or the Hostinger firewall (step 21), or the 2 minutes ran out (repeat step 22, then this one). Do not go on to step 24.

### 24. VPS root: write the sshd settings (both ports for now) and check what sshd will really use

```bash
grep -rnE '^\s*Port' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ || echo no-port-lines
[[ $SSH_PORT =~ ^[0-9]+$ ]] && cat >/etc/ssh/sshd_config.d/00-isoca.conf <<EOF
Port 22
Port $SSH_PORT
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
sshd -t && sshd -T | grep -Ei '^(port|passwordauthentication|permitrootlogin|kbdinteractiveauthentication) ' 
```

→ expected: first `no-port-lines` (an active `Port` line in `sshd_config` is a problem for step 28: comment it out now with `sed -i 's/^\s*Port /#Port /' /etc/ssh/sshd_config` and repeat); then no error from `sshd -t`, then five lines in any order: `port 22`, `port <your port>`, `passwordauthentication no`, `permitrootlogin no`, `kbdinteractiveauthentication no`. (`00-` sorts before cloud-init's `50-cloud-init.conf`; sshd keeps the first value it reads.)
if not: **STOP.** Nothing is restarted yet. An `sshd -t` error: fix the file now, before closing any window; the Hostinger browser console takes the root password if you get locked out. A value that differs -> `grep -ri passwordauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/` shows who sets it. Missing port lines -> step 14 was not done (`echo $SSH_PORT`). To undo: `rm /etc/ssh/sshd_config.d/00-isoca.conf`.

### 25. VPS root: apply it (Ubuntu 26.04 starts sshd from ssh.socket, so the socket restarts too)

```bash
systemctl daemon-reload && systemctl restart ssh.socket && systemctl restart ssh && ss -ltn | grep -E ":(22|$SSH_PORT) "
```

→ expected: `LISTEN` lines for port 22 and your port (0.0.0.0 and [::]). Window A stays connected.
if not: only port 22 listed -> `systemctl disable --now ssh.socket && systemctl enable --now ssh`, then `ss -ltn` again. Nothing listed at all -> **STOP**: in window A `sshd -t`, `journalctl -u ssh -n 30`; do not close window A.

### 26. PC Git Bash (a new window, window B): log in as admin on the NEW port. **STOP** if it fails.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" -o PasswordAuthentication=no "$ADMIN@$VPS_IP" 'echo "connected on port ${SSH_CONNECTION##* }"; sudo -v && echo sudo-ok'
```

→ expected: a host-key question for the new port (`yes`), `connected on port <your port>`, the sudo password prompt, `sudo-ok`. Leave window B open.
if not: **STOP.** Window A still works on both ports: repeat step 24's check and `journalctl -u ssh -n 30` there. Do not do step 28.

### 27. PC Git Bash: root and passwords are refused on the new port

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -p "$SSH_PORT" -o BatchMode=yes root@"$VPS_IP" true; ssh -p "$SSH_PORT" -o BatchMode=yes -o PubkeyAuthentication=no "$ADMIN@$VPS_IP" true
```

→ expected: `Permission denied (publickey).` twice.
if not: either command logs in -> **STOP**; in window A run step 24's `sshd -T` line and look for a `Match` block or another config file.

### 28. VPS root (window A): drop port 22 from sshd

```bash
[[ $SSH_PORT =~ ^[0-9]+$ ]] && cat >/etc/ssh/sshd_config.d/00-isoca.conf <<EOF
Port $SSH_PORT
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl daemon-reload && systemctl restart ssh.socket && systemctl restart ssh && ss -ltn | grep -E ":(22|$SSH_PORT) " 
```

→ expected: `LISTEN` lines for your port only; none for 22.
if not: an `sshd -t` error: fix the file now, before closing any window; the Hostinger browser console takes the root password if you get locked out. Port 22 still listed -> wait 5 seconds and repeat `ss`; still there -> `grep -rnE '^\s*Port' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/` (ports add up across files) and comment out the extra line with `sed -i 's/^\s*Port 22/#Port 22/' /etc/ssh/sshd_config`, then repeat the last line; last resort `systemctl disable --now ssh.socket && systemctl enable --now ssh`. Window A lost -> use window B: `sudo -i`, then step 14.

### 29. PC Git Bash: a fresh login on the new port works, port 22 is closed, then remove the old port from ufw

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -p "$SSH_PORT" -o BatchMode=yes "$ADMIN@$VPS_IP" 'echo login-ok'; (timeout 5 bash -c "exec 3<>/dev/tcp/$VPS_IP/22" && echo "22 OPEN" || echo "22 closed"); ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo ufw delete allow 22/tcp && sudo ufw status' 
```

→ expected: `login-ok`, `22 closed`, then (after the sudo password) a ufw status with no 22 lines; your port, 80, 443 allowed.
if not: `22 OPEN` -> step 28 did not take; repeat it, and do not delete the ufw rule (press Ctrl-C at the sudo prompt; do not delete the ufw rule). No `login-ok` -> **STOP**, use window A. ufw lines for 22 left -> in window A `ufw status numbered`, then `ufw delete <n>` for each.

### 30. Hostinger browser: remove 22 from the panel firewall

```text
Hostinger panel > VPS > this server > Security > Firewall: delete the TCP 22 rule. Keep SSH_PORT, 80, 443.
```

→ expected: three TCP rules left (or no panel firewall).
if not: leave it; sshd and ufw already keep port 22 closed.

### 31. VPS root: fail2ban on the new port

```bash
[[ $SSH_PORT =~ ^[0-9]+$ ]] && cat >/etc/fail2ban/jail.d/isoca-sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable fail2ban && systemctl restart fail2ban && sleep 3 && fail2ban-client status sshd && fail2ban-client -d | grep -q "\['port', '$SSH_PORT'\]" && echo port-ok
```

→ expected: `Status for the jail: sshd`, then `port-ok`.
if not: `journalctl -u fail2ban -n 30`; `fail2ban-client -d | grep -i port` shows the port the jail uses. No `port-ok` means the jail is not on your port: it protects nothing.

### 32. VPS root: automatic security updates, and both services running

```bash
dpkg-reconfigure -f noninteractive unattended-upgrades && cat /etc/apt/apt.conf.d/20auto-upgrades && systemctl is-active fail2ban unattended-upgrades
```

→ expected: `APT::Periodic::Update-Package-Lists "1";`, `APT::Periodic::Unattended-Upgrade "1";`, then `active` twice.
if not: `systemctl enable --now unattended-upgrades`, repeat.

### 33. VPS root: Docker's signing key (must match), then Docker Engine from Docker's apt repo

```bash
install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc && FPR=$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '/^fpr/ {print $10; exit}') && [ "$FPR" = 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ] && echo fingerprint-ok && tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update && apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && docker --version && docker compose version
```

→ expected: the first run prints three `gpg:` lines (noise), then `fingerprint-ok`, then the install, then `Docker version ...` and `Docker Compose version v5...`. The fingerprint is the one on docs.docker.com, Install on Ubuntu.
if not: **STOP** with no `fingerprint-ok`: `rm /etc/apt/keyrings/docker.asc` and compare with docs.docker.com before going on. A bad repo: `cat /etc/apt/sources.list.d/docker.sources` (the `Suites:` line must read `resolute`), fix it, repeat the last line.

### 34. VPS root: cap container logs, then test Docker

```bash
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
EOF
systemctl restart docker && docker info --format '{{.LoggingDriver}}' && docker run --rm hello-world | grep -m1 'Hello from Docker'
```

→ expected: `json-file` then `Hello from Docker!`
if not: `journalctl -u docker -n 30` (a typo in `daemon.json` is the usual cause).

### 35. VPS root: the two service users, in no `sudo` and no `docker` group

```bash
adduser --disabled-password --gecos "" deploy && adduser --disabled-password --gecos "" claude && usermod -aG systemd-journal claude && for u in deploy claude; do echo "$u: $(id -nG $u)"; done
```

→ expected: some `adduser` noise (`usermod: no changes` is harmless), then `deploy: deploy users` and `claude: claude users systemd-journal`. The rule: neither user has `sudo` or `docker` in its list.
if not: `sudo` or `docker` listed -> `gpasswd -d <user> <group>`, repeat only the last loop. `user already exists` -> run only `usermod -aG systemd-journal claude` and the loop.

### 36. VPS root: the directories, the tools the deploy script needs, and a check

```bash
install -d -o root -g root -m 0755 /srv /srv/sites /srv/edge && install -d -o deploy -g deploy -m 0755 /srv/sites/radar /srv/sites/radar/releases /srv/edge/dynamic && install -d -o deploy -g deploy -m 0700 /srv/edge/.incoming && install -d -o 65532 -g 65532 -m 0700 /srv/edge/acme && command -v flock tar gzip && [ "$(stat -c %d /srv/edge/.incoming)" = "$(stat -c %d /srv/edge/dynamic)" ] && echo same-filesystem; stat -c '%U(%u):%G(%g) %a %n' /srv /srv/sites /srv/sites/radar /srv/sites/radar/releases /srv/edge /srv/edge/dynamic /srv/edge/.incoming /srv/edge/acme
```

→ expected: three paths (`flock`, `tar`, `gzip`), `same-filesystem`, then `root(0):root(0) 755` for `/srv`, `/srv/sites`, `/srv/edge`; `deploy(..):deploy(..) 755` for `/srv/sites/radar`, `/srv/sites/radar/releases`, `/srv/edge/dynamic`; `deploy(..):deploy(..) 700` for `/srv/edge/.incoming`; `UNKNOWN(65532):UNKNOWN(65532) 700` for `/srv/edge/acme`.
if not: `invalid user` -> step 35 did not run. A missing tool -> `apt-get install -y util-linux tar gzip`. No `same-filesystem` -> **STOP** (the config upload needs one filesystem; look at `df /srv/edge/.incoming /srv/edge/dynamic`). A wrong owner or mode -> repeat the `install -d` lines.

### 37. VPS root: clone isoca-infra, install the deploy command, copy the Traefik files, check what the containers must read

```bash
umask 022 && GIT_TERMINAL_PROMPT=0 git clone https://github.com/isabellybaldo/isoca-infra /srv/isoca-infra && install -o root -g root -m 0755 /srv/isoca-infra/box/site-deploy /usr/local/bin/site-deploy && install -o deploy -g deploy -m 0644 /srv/isoca-infra/edge/dynamic/*.yml /srv/edge/dynamic/ && ls -l /usr/local/bin/site-deploy /srv/edge/dynamic && git -C /srv/isoca-infra log --oneline -1 && stat -c '%a %n' /srv/isoca-infra /srv/isoca-infra/edge /srv/isoca-infra/edge/traefik.yml /srv/isoca-infra/edge/nginx /srv/isoca-infra/edge/nginx/sites.conf
```

→ expected: the clone finishes; `site-deploy` is `-rwxr-xr-x root root`; `common.yml`, `isoca.yml`, `radar.yml` are `-rw-r--r-- deploy deploy`; the commit you pushed in step 4; then `755`, `755`, `644`, `755`, `644` in that order (Traefik, uid 65532, and nginx, uid 101, must read these).
if not: "could not read Username" or "not found" -> isoca-infra is not public, or step 4 did not push; fix that, `rm -rf /srv/isoca-infra`, repeat. Wrong modes -> `chmod -R go+rX /srv/isoca-infra` and repeat the last `stat`.

### 38. VPS root: `authorized_keys` of `deploy` (forced command) and of `claude`

```bash
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh && printf 'restrict,command="/usr/local/bin/site-deploy" %s\n' "$(cat /root/isoca_deploy.pub)" >/home/deploy/.ssh/authorized_keys && chown deploy:deploy /home/deploy/.ssh/authorized_keys && chmod 600 /home/deploy/.ssh/authorized_keys && install -d -m 700 -o claude -g claude /home/claude/.ssh && install -m 600 -o claude -g claude /root/isoca_claude.pub /home/claude/.ssh/authorized_keys && cut -c1-70 /home/deploy/.ssh/authorized_keys /home/claude/.ssh/authorized_keys
```

→ expected: two lines: `restrict,command="/usr/local/bin/site-deploy" ssh-ed25519 AAAA...` and `ssh-ed25519 AAAA...`
if not: `No such file ... .pub` -> repeat step 16.

### 39. PC Git Bash: the deploy key can only run site-deploy. **STOP** on a shell or any other output.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && DEPLOY_KEY_PATH=$(cygpath -m "$DEPLOY_KEY_PATH") && for c in bogus ls "rollback radar"; do echo "== $c"; ssh -i "$DEPLOY_KEY_PATH" -o IdentitiesOnly=yes -o BatchMode=yes -p "$SSH_PORT" "deploy@$VPS_IP" "$c"; done
```

→ expected: `== bogus` then `refused: unknown command`; `== ls` then `refused: unknown command`; `== rollback radar` then `refused: no current release`
if not: **STOP** if you get a shell or a directory listing: in window A run `: > /home/deploy/.ssh/authorized_keys`, then check step 38. `Permission denied (publickey)` -> in window A: `usermod -p '*' deploy` (a locked account), `journalctl -u ssh -n 20`, repeat.

### 40. PC Git Bash: no port forwarding and no file copy with the deploy key

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && DEPLOY_KEY_PATH=$(cygpath -m "$DEPLOY_KEY_PATH") && F=$(mktemp) && echo x >"$F" && F=$(cygpath -m "$F"); ssh -W 127.0.0.1:80 -i "$DEPLOY_KEY_PATH" -o IdentitiesOnly=yes -o BatchMode=yes -p "$SSH_PORT" "deploy@$VPS_IP" </dev/null; echo "forward exit: $?"; scp -i "$DEPLOY_KEY_PATH" -P "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes "$F" "deploy@$VPS_IP:x"; echo "scp exit: $?"
```

→ expected: `channel ...: open failed: administratively prohibited` and/or `stdio forwarding failed`, and `forward exit: 255`; then an scp error (`Connection closed`, or a `refused:` line) and an `scp exit:` that is not 0.
if not: **STOP** if `forward exit` is not 255, or scp exits 0: `restrict` is missing in the deploy line (step 38). `Connection refused` instead of `prohibited` means the forward was allowed through.

### 41. PC Git Bash: the claude key is a plain login with no sudo and no docker

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && CLAUDE_KEY_PATH=$(cygpath -m "$CLAUDE_KEY_PATH") && ssh-add "$CLAUDE_KEY_PATH" && ssh -i "$CLAUDE_KEY_PATH" -o IdentitiesOnly=yes -p "$SSH_PORT" "claude@$VPS_IP" 'id -nG; sudo -n true 2>&1 | head -1; docker ps 2>&1 | head -1'
```

→ expected: your `isoca_claude` passphrase once, at `ssh-add`, then `Identity added: ...isoca_claude` (the agent now holds the key, so Claude Code can use it without a prompt), then `claude users systemd-journal`, a `sudo:` line refusing (sudo-rs says `I'm sorry claude. I'm afraid I can't do that`), and `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`. The rule: no `sudo`, no `docker`.
if not: sudo or docker works for claude -> **STOP**, redo step 35. `Permission denied (publickey)` -> `usermod -p '*' claude` in window A, repeat.

### 42. VPS root: start the edge

```bash
docker compose -f /srv/isoca-infra/edge/compose.yml up -d
```

→ expected: images pulled, then `Container edge-nginx-1 Started` and `Container edge-traefik-1 Started`.
if not: `docker compose -f /srv/isoca-infra/edge/compose.yml logs --tail 50`; a "permission denied" on `/acme` -> redo step 36.

### 43. VPS root: it is up, it redirects, and read the log once

```bash
sleep 20; docker compose -f /srv/isoca-infra/edge/compose.yml ps; curl -sI http://localhost | head -3; docker compose -f /srv/isoca-infra/edge/compose.yml logs traefik 2>&1 | grep -E 'ERR|FTL' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-170 | head -8
```

→ expected: nginx `healthy`, traefik `Up`; `HTTP/1.1 308` (or `301`) with `Location: https://localhost/`; a few `ERR` lines with `Unable to obtain ACME certificate` naming radar, isoca, www and new.isoca.space are normal now, because DNS does not point here yet (runbook 2 fixes that). Do not restart Traefik over and over: Let's Encrypt allows 5 failed validations per host per hour.
if not: nginx `unhealthy` -> `docker compose -f /srv/isoca-infra/edge/compose.yml logs nginx`. Any other error line (not ACME) -> read it before going on.

### 44. VPS root: print the box's host key line (select it and copy it)

```bash
cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub
```

→ expected: one line `ssh-ed25519 AAAA...`
if not: `ls /etc/ssh/ssh_host_*.pub`.

### 45. PC Git Bash: scan the box and compare with its own key. **STOP** on a mismatch.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && KH="$HOME/.ssh/isoca_known_hosts.tmp" && /usr/bin/ssh-keyscan -p "$SSH_PORT" -t ed25519 "$VPS_IP" 2>/dev/null | tr -d '\r' >"$KH" && [ "$(wc -l <"$KH")" = 1 ] && read -r -p "paste the line from step 44: " L && [ "$(cut -d' ' -f2- "$KH")" = "$L" ] && echo MATCH || echo MISMATCH
```

→ expected: after you paste the line from step 44: `MATCH`
if not: **STOP.** `MISMATCH` -> repeat steps 44 and 45 once; if it still differs, something sits between you and the box. Do not store these keys in GitHub.

### 46. PC Git Bash: environment `production` in both repos, limited to `main`

```bash
for R in isoca-radar isoca-infra; do gh api -X PUT "repos/isabellybaldo/$R/environments/production" --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' >/dev/null && gh api -X POST "repos/isabellybaldo/$R/environments/production/deployment-branch-policies" -f name=main -f type=branch >/dev/null; echo "$R: $(gh api "repos/isabellybaldo/$R/environments/production/deployment-branch-policies" -q '[.branch_policies[].name]|join(",")')"; done
```

→ expected: `isoca-radar: main` and `isoca-infra: main`
if not: 404 or 403 -> the repo is not public (step 7 or step 4) or `gh auth status` lacks admin rights. 422 "already exists" is fine. By hand: repo Settings > Environments > New environment `production` > Deployment branches and tags > Selected branches and tags > Add deployment branch or tag rule > `main`.

### 47. PC Git Bash: the four secrets in both environments, from files (no pasting)

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && DEPLOY_KEY_PATH=$(cygpath -m "$DEPLOY_KEY_PATH") && KH="$HOME/.ssh/isoca_known_hosts.tmp" && for R in isoca-radar isoca-infra; do tr -d '\r' <"$DEPLOY_KEY_PATH" | gh secret set DEPLOY_SSH_KEY -e production -R "isabellybaldo/$R" && printf '%s' "$VPS_IP" | gh secret set DEPLOY_HOST -e production -R "isabellybaldo/$R" && printf '%s' "$SSH_PORT" | gh secret set DEPLOY_PORT -e production -R "isabellybaldo/$R" && gh secret set DEPLOY_KNOWN_HOSTS -e production -R "isabellybaldo/$R" <"$KH"; echo "$R: $(gh secret list -e production -R "isabellybaldo/$R" | cut -f1 | sort | tr '\n' ' ')"; done
```

→ expected: `isoca-radar: DEPLOY_HOST DEPLOY_KNOWN_HOSTS DEPLOY_PORT DEPLOY_SSH_KEY` and the same for `isoca-infra`.
if not: the environment is missing -> step 46. One secret missing -> repeat this step. (The browser works too: repo Settings > Environments > production > Add environment secret; pasting is where line endings go wrong, which is why this step reads files.)

### 48. PC Git Bash: delete the local deploy key (it now lives only in GitHub)

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && rm -f "$DEPLOY_KEY_PATH" "$DEPLOY_KEY_PATH.pub" "$HOME/.ssh/isoca_known_hosts.tmp"; ls ~/.ssh | grep -c isoca_deploy
```

→ expected: `0`
if not: a file still matches -> `ls ~/.ssh`, delete it. To rotate the key later: new pair, replace the deploy line in `/home/deploy/.ssh/authorized_keys`, redo steps 47 and 48.

### 49. VPS root: remove the copied public keys, then reboot (proves everything comes back)

```bash
rm -f /root/owner.pub /root/isoca_deploy.pub /root/isoca_claude.pub && reboot
```

→ expected: the connection of window A closes.
if not: `systemctl reboot`.

### 50. PC Git Bash: after the reboot: login, edge, firewall, services

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && until ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$ADMIN@$VPS_IP" true 2>/dev/null; do sleep 5; done; ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo docker compose -f /srv/isoca-infra/edge/compose.yml ps; sudo ufw status | head -1; systemctl is-active fail2ban ssh'
```

→ expected: within a few minutes: the sudo password, nginx `healthy` and traefik `Up`, `Status: active`, then `active` twice.
if not: Ctrl-C the wait after 5 minutes and look through the Hostinger panel's browser console (`systemctl status ssh.socket docker`). The box is ready for runbook 2 only when this step is clean.

