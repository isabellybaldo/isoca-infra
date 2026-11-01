# Runbook 3: play.isoca.space

Owner-run: every push, merge, root step and GitHub change. Every step is one block, then `→ expected:`, then `if not:`. **STOP** means: do not go on until it is fixed.
Values come from `local.env` (`VPS_IP`, `SSH_PORT`, `ADMIN`) and never go in this repo. On the box nothing is saved: paste when a step asks.

Where a step runs:

- **PC Git Bash**: new window, opened after runbook 1 step 8.
- **VPS root**: window A, from step 6. Keep it open. Lost: repeat step 6.
- **GitHub browser**, **Your Chrome**, **Phone**: as named.

Way back from any lockout: the Hostinger panel's browser console. No step here changes sshd, ufw or the admin login.

```
checks > radar still up > push play (not merged) > new site-deploy > old key refused play > box dirs, units
  > play key > isoca-play repo (docs only), environment, secrets, settings, ruleset
  > DNS again > MERGE isoca-infra (route, certificate) > box pull
  > MERGE isoca-play (publish) > package public > approve deploy > password > checks > drill > phone
```

## Before anything

### 1. PC Git Bash: `local.env`, your login, the two branches

```bash
cd ~/PycharmProjects/isoca-infra && [ "$(tr -cd '\r' < local.env | wc -c)" = 0 ] && set -a && . ./local.env && set +a && [[ $VPS_IP =~ ^[0-9]+(\.[0-9]+){3}$ && $VPS_IP != 203.0.113.10 && $SSH_PORT =~ ^[0-9]+$ && -n $ADMIN ]] && echo local-env-ok; gh api user -q .login; git status --short | wc -l; git rev-parse --abbrev-ref HEAD; git -C ../isoca-play status --short | wc -l; git -C ../isoca-play rev-parse --abbrev-ref HEAD; git -C ../isoca-play merge-base --is-ancestor main design-check && echo main-under-design-check; git -C ../isoca-play ls-tree main .github | wc -l; git -C ../isoca-play remote | wc -l
```

→ expected: `local-env-ok`, `isabellybaldo`, `0`, `play`, `0`, `design-check`, `main-under-design-check`, `0`, `0`.
if not: **STOP.** A last `1`: isoca-play already has a remote; `gh repo view isabellybaldo/isoca-play` and start step 18 at what is missing. The `0` before it must stay `0`: local `main` holds docs only, so its push runs no workflow.

### 2. PC Git Bash: gitleaks over all history, both repos

```bash
cd ~/PycharmProjects && for r in isoca-infra isoca-play; do echo "== $r"; MSYS_NO_PATHCONV=1 docker run --rm -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' -v "$(cygpath -m "$PWD/$r"):/scan:ro" zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f git /scan --redact --log-opts="--all" 2>&1 | tail -n 1; done
```

→ expected: `no leaks found` under each name.
if not: **STOP.** Nothing is pushed yet. Read the finding: rerun without `tail`.

### 3. PC Git Bash: your private values are in neither history

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && for r in . ../isoca-play; do echo "$r ip $(git -C "$r" log --all -p | grep -cF "$VPS_IP") admin $(git -C "$r" log --all -p | grep -cwF "$ADMIN")"; done; bash tests/no-secrets.sh
```

→ expected: `. ip 0 admin 0`, `../isoca-play ip 0 admin 0`, `no-secrets: clean (...)`.
if not: **STOP** on any `ip` above 0. An `admin` above 0: look with `git log --all -p | grep -wF "$ADMIN"`; a common word is fine, your login is not.

### 4. PC Git Bash: radar and portfolio serve now (the baseline)

```bash
for u in https://radar.isoca.space/ https://radar.isoca.space/math https://radar.isoca.space/sweet https://isoca.space/ https://www.isoca.space/ https://isabellybaldo.github.io/; do curl -s -o /dev/null -w "%{http_code} $u\n" "$u"; done
```

→ expected: `200`, `200`, `200`, `302`, `302`, `200`.
if not: **STOP.** Fix that first (runbook 2, "If something breaks later"), or later checks mean nothing.

### 5. PC Git Bash: DNS is a check only: `play` already points to the box, no AAAA

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a; for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do echo "A $(curl -s -H 'accept: application/dns-json' "$u?name=play.isoca.space&type=A" | grep -cE "\"data\": ?\"$VPS_IP\"") AAAA $(curl -s -H 'accept: application/dns-json' "$u?name=play.isoca.space&type=AAAA" | grep -cE '"Answer":.*"type": ?28')"; done
```

→ expected: `A 1 AAAA 0` twice.
if not: **STOP.** Hostinger panel > DNS: fix the `play` A record (points to `VPS_IP`, TTL 300) or delete its AAAA record, wait 5 minutes, repeat.

### 6. PC Git Bash: window A: a root shell on the box (keep it open)

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo -i'
```

→ expected: the sudo password, then a `root@...#` prompt.
if not: `ssh-add -l` empty: runbook 1 step 8. Banned: Hostinger console, `fail2ban-client unban --all`.

### 7. PC Git Bash: isoca-infra and isoca-radar: who can do what. Read only: change nothing here.

```bash
for R in isabellybaldo/isoca-infra isabellybaldo/isoca-radar; do echo "== $R"; echo "collaborators: $(gh api "repos/$R/collaborators" --paginate -q '.[].login' | tr '\n' ' ')"; echo "invitations: $(gh api "repos/$R/invitations" -q length)"; echo "deploy keys: $(gh api "repos/$R/keys" -q length)"; echo "token: $(gh api "repos/$R/actions/permissions/workflow" -q .default_workflow_permissions)"; echo "fork approval: $(gh api "repos/$R/actions/permissions/fork-pr-contributor-approval" -q .approval_policy)"; echo "env rules: $(gh api "repos/$R/environments/production" -q '[.protection_rules[].type]|sort|join(",")')"; echo "env branches: $(gh api "repos/$R/environments/production/deployment-branch-policies" -q '[.branch_policies[].name]|join(",")')"; echo "main rules: $(gh api "repos/$R/rules/branches/main" -q '[.[].type]|sort|join(",")')"; done
```

→ expected, for each repo: `collaborators: isabellybaldo`, `invitations: 0`, `deploy keys: 0`, `token: read`, `fork approval: all_external_contributors`, `env rules: branch_policy,required_reviewers`, `env branches: main`, `main rules: deletion,non_fast_forward,pull_request,required_status_checks`. Endpoints confirmed in GitHub's REST docs; the type names `branch_policy` and `required_reviewers` are unconfirmed (the docs do not list them): if they read differently, check Settings > Environments > production.
if not: a collaborator, invitation or deploy key you do not know -> **STOP**. Any other difference: write it down and finish it in your separate work on these two repos; this runbook does not change them. Known on 11-01: both at `first_time_contributors`, neither with a required reviewer, isoca-radar with no main rules. If isoca-infra has the reviewer by then, its runs in steps 11, 12 and 25 wait for your click: run page > Review deployments > production > Approve.

## New site-deploy first

### 8. PC Git Bash: push `play`, open the pull request, do NOT merge

```bash
cd ~/PycharmProjects/isoca-infra && R=isabellybaldo/isoca-infra && git push origin refs/heads/play:refs/heads/play && gh pr create -R "$R" --base main --head play --title "play: the route, the service, a release-only key, runbook 3" --body "Runbook 3 says when to merge." ; sleep 15; gh pr checks play -R "$R" --watch; git rev-parse refs/heads/play
```

→ expected: a pull request URL, then `checks` passing (some minutes), then the 40-hex commit. Copy that commit. Nothing reaches the box: `edge-config` runs only on main.
if not: **STOP** on red `checks`: `gh pr checks play -R "$R"`, read the log, fix on the branch. This is the first time every test runs together on Linux. Do not weaken the ruleset to get past it.

### 9. VPS root: keep the old site-deploy, install the new one from that exact commit

```bash
read -r -p "commit from step 8: " C; [[ $C =~ ^[0-9a-f]{40}$ ]] && git -C /srv/isoca-infra fetch origin refs/heads/play && [ "$(git -C /srv/isoca-infra rev-parse FETCH_HEAD)" = "$C" ] && echo commit-ok && T=$(mktemp -d) && git -C /srv/isoca-infra show "$C:box/site-deploy" >"$T/site-deploy" && bash -n "$T/site-deploy" && { [ -e /usr/local/bin/site-deploy.before-play ] || cp -p /usr/local/bin/site-deploy /usr/local/bin/site-deploy.before-play; } && install -o root -g root -m 0755 "$T/site-deploy" /usr/local/bin/site-deploy && rm -rf "$T" && ls -l /usr/local/bin/site-deploy /usr/local/bin/site-deploy.before-play && grep -c -- --only-play /usr/local/bin/site-deploy
```

→ expected: `commit-ok`, two `-rwxr-xr-x root root` lines, a number above 0.
if not: **STOP.** No `commit-ok`: the push is not what you reviewed; nothing was installed. Undo at any time: `install -m 0755 /usr/local/bin/site-deploy.before-play /usr/local/bin/site-deploy`.

### 10. VPS root: arguments are refused, the old command line is refused play verbs, and the old key's line is untouched

```bash
sd() { echo "== [$1] $2"; runuser -u deploy -- env SSH_ORIGINAL_COMMAND="$2" /usr/local/bin/site-deploy $1 </dev/null; echo "exit $?"; }; sd --typo bogus; sd "--only-play extra" "rollback play"; sd --ONLY-PLAY "rollback play"; sd "" "rollback play"; sd "" "release play sha256:$(printf '0%.0s' {1..64})"; sd "" bogus; wc -l </home/deploy/.ssh/authorized_keys; cut -c1-56 /home/deploy/.ssh/authorized_keys
```

→ expected: three times `refused: bad arguments`, `exit 2`; twice `refused: play has its own key`, `exit 2`; `refused: unknown command`, `exit 2`; then `1` and `restrict,command="/usr/local/bin/site-deploy" ssh-ed25519`.
if not: **STOP.** Do not add any key. Undo with the line in step 9's `if not`. A bare `bad arguments` missing means a typo in `authorized_keys` could fall back to full powers.

### 11. PC Git Bash: the real old key is refused play verbs (its only copy is in GitHub, so a workflow carries it)

```bash
I=isabellybaldo/isoca-infra; OLD=$(gh run list -R $I -w rollback.yml -L 1 --json databaseId -q '.[0].databaseId'); gh workflow run rollback.yml -R $I -f site=play && until RID=$(gh run list -R $I -w rollback.yml -L 1 --json databaseId -q '.[0].databaseId'); [ -n "$RID" ] && [ "$RID" != "$OLD" ]; do sleep 3; done; gh run watch "$RID" -R $I --exit-status >/dev/null; echo "run exit $?"; gh run view "$RID" -R $I --log-failed | grep -oE 'refused: [a-z ]+' | tail -n 1
```

→ expected: `run exit 1` (this run must go red), then `refused: play has its own key`.
if not: **STOP.** Do not add any key. `refused: unknown site`: the old site-deploy still runs; repeat step 9. `run exit 0`: something was rolled back: read the run, `ls /srv/sites`, and repair before going on.

### 12. PC Git Bash: the real old key still does its work, and radar and portfolio serve. **STOP** if not.

```bash
I=isabellybaldo/isoca-infra; OLD=$(gh run list -R $I -w edge-config.yml -L 1 --json databaseId -q '.[0].databaseId'); gh workflow run edge-config.yml -R $I && until RID=$(gh run list -R $I -w edge-config.yml -L 1 --json databaseId -q '.[0].databaseId'); [ -n "$RID" ] && [ "$RID" != "$OLD" ]; do sleep 3; done; gh run watch "$RID" -R $I --exit-status >/dev/null; gh run view "$RID" -R $I --log | grep -oE 'edge config [0-9]+ files' | tail -n 1; for u in https://radar.isoca.space/ https://radar.isoca.space/math https://radar.isoca.space/sweet https://isoca.space/ https://www.isoca.space/ https://isabellybaldo.github.io/; do curl -s -o /dev/null -w "%{http_code} $u\n" "$u"; done
```

→ expected: `edge config 3 files` (from main, which has no route yet), then `200`, `200`, `200`, `302`, `302`, `200`.
if not: **STOP.** Undo with step 9's line, then repeat this step. Every later step leaves this one good.

## The box

### 13. VPS root: directories and the network the container needs

```bash
install -d -o root -g root -m 0755 /srv/play && install -d -o 10001 -g 10001 -m 0700 /srv/play/data && install -d -o deploy -g deploy -m 0755 /srv/play/state && stat -c '%U(%u):%G(%g) %a %n' /srv/play /srv/play/data /srv/play/state; [ "$(stat -c %d /srv/play)" = "$(stat -c %d /srv/play/state)" ] && echo same-filesystem; docker network inspect edge_edge --format '{{.Name}} internal={{.Internal}}'
```

→ expected: `root(0):root(0) 755 /srv/play`; `... (10001): ... (10001) 700 /srv/play/data` (the name may read `UNKNOWN`); `deploy(..):deploy(..) 755 /srv/play/state`; `same-filesystem`; `edge_edge internal=true`.
if not: **STOP.** No `same-filesystem`: the state rename is not atomic. No network: `docker compose -f /srv/isoca-infra/edge/compose.yml up -d`.

### 14. VPS root: play-apply and its units, from the same commit

```bash
read -r -p "commit from step 8: " C; [[ $C =~ ^[0-9a-f]{40}$ ]] && [ "$(git -C /srv/isoca-infra rev-parse "$C^{commit}")" = "$C" ] && T=$(mktemp -d) && git -C /srv/isoca-infra archive "$C" box | tar -x -C "$T" && bash -n "$T/box/play-apply" && install -o root -g root -m 0755 "$T/box/play-apply" /usr/local/bin/play-apply && install -o root -g root -m 0644 "$T/box/play-apply.path" "$T/box/play-apply.service" "$T/box/play-apply.timer" /etc/systemd/system/ && rm -rf "$T" && systemctl daemon-reload && systemctl enable --now play-apply.path play-apply.timer && systemctl is-active play-apply.path play-apply.timer; systemctl start play-apply.service; echo "run exit $?"; ls -A /srv/play/state | wc -l
```

→ expected: `active`, `active`, `run exit 0`, `0` (no release yet: the run does nothing and writes nothing).
if not: `journalctl -u play-apply -n 30`, `systemctl status play-apply.path`. This touches nothing that serves.

## The play key

### 15. PC Git Bash: a new key pair, then print its public line

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; K="$HOME/.ssh/isoca_play"; [ ! -e "$K" ] && ssh-keygen -t ed25519 -N "" -C isoca_play -f "$(cygpath -m "$K")" >/dev/null && cut -d' ' -f1,2 "$K.pub"
```

→ expected: one line `ssh-ed25519 AAAA...`. Copy it.
if not: the file exists: it is left from a run that did not finish step 22. Look at it; delete both files only if unused.

### 16. VPS root: add the play line. **Only after steps 10, 11 and 12 passed.**

```bash
read -r -p "public line from step 15: " PUB; [[ $PUB =~ ^ssh-ed25519\ AAAA[A-Za-z0-9+/=]+$ ]] && ! grep -q -- --only-play /home/deploy/.ssh/authorized_keys && printf 'restrict,command="/usr/local/bin/site-deploy --only-play" %s\n' "$PUB" >>/home/deploy/.ssh/authorized_keys; wc -l </home/deploy/.ssh/authorized_keys; cut -c1-68 /home/deploy/.ssh/authorized_keys; stat -c '%U %a' /home/deploy/.ssh/authorized_keys
```

→ expected: `2`; the old `restrict,command="/usr/local/bin/site-deploy" ssh-ed25519 ...` line; `restrict,command="/usr/local/bin/site-deploy --only-play" ssh-ed25519 ...`; `deploy 600`.
if not: **STOP.** To remove the play line: `sed -i '/--only-play/d' /home/deploy/.ssh/authorized_keys`. Never touch the first line: radar and edge deploys need it.

### 17. PC Git Bash: the play key does nothing else. **STOP** on a shell, a listing or a forward.

Never test `release play sha256:...` here: it would start a real apply.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && K=$(cygpath -m "$HOME/.ssh/isoca_play") && S=(-i "$K" -o IdentitiesOnly=yes -o BatchMode=yes -p "$SSH_PORT" "deploy@$VPS_IP"); for c in bogus ls edge-config "rollback radar" "deploy radar 20260101T000000Z-abcdef0" "rollback play"; do echo "== $c"; ssh "${S[@]}" "$c" </dev/null; done; ssh -W 127.0.0.1:80 "${S[@]}" </dev/null; echo "forward exit: $?"; F=$(mktemp) && echo x >"$F" && scp -i "$K" -P "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes "$(cygpath -m "$F")" "deploy@$VPS_IP:x"; echo "scp exit: $?"; rm -f "$F"; ssh -tt "${S[@]}" bogus </dev/null
```

→ expected: the first five each `refused: this key can only release and roll back play`; `rollback play` gives `refused: no previous play release`; `administratively prohibited` and/or `stdio forwarding failed`, `forward exit: 255`; an scp error and a non-zero `scp exit:`; `PTY allocation request failed` then the same refusal.
if not: **STOP.** In window A: `sed -i '/--only-play/d' /home/deploy/.ssh/authorized_keys`, then read step 16's output. Radar is not affected.

## isoca-play on GitHub

### 18. PC Git Bash: create the public repo, named exactly `isoca-play`, push docs-only `main`, check who has access

```bash
cd ~/PycharmProjects/isoca-play && R=isabellybaldo/isoca-play && gh repo create "$R" --public --description "Sudoku and mahjong for one player" && git remote add origin "https://github.com/$R.git" && git push origin refs/heads/main:refs/heads/main && gh repo view "$R" --json name,visibility,defaultBranchRef -q '[.name,.visibility,.defaultBranchRef.name]|join(" ")'; gh run list -R "$R" -L 5 --json name -q length; echo "collaborators: $(gh api "repos/$R/collaborators" --paginate -q '.[].login' | tr '\n' ' ')"; echo "invitations: $(gh api "repos/$R/invitations" -q length)"; echo "deploy keys: $(gh api "repos/$R/keys" -q length)"
```

→ expected: `isoca-play PUBLIC main`; `0` runs; `collaborators: isabellybaldo`; `invitations: 0`; `deploy keys: 0`.
if not: **STOP.** `name already exists`: `gh repo view "$R"`, then run only what is missing. The image name and the box's fixed name rely on this exact repo name. Anyone else listed: remove them in Settings > Collaborators.

### 19. PC Git Bash: `production`: main only, you as required reviewer, and self-approval allowed

```bash
R=isabellybaldo/isoca-play; ME=$(gh api user -q .id) && gh api -X PUT "repos/$R/environments/production" --input - >/dev/null <<EOF
{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":$ME}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
[ -n "$(gh api "repos/$R/environments/production/deployment-branch-policies" -q '.branch_policies[]|select(.name=="main")|.name')" ] || gh api -X POST "repos/$R/environments/production/deployment-branch-policies" -f name=main -f type=branch >/dev/null; gh api "repos/$R/environments/production" -q '.protection_rules[]|select(.reviewers)|[(.reviewers[].reviewer.login),"self-review-blocked="+(.prevent_self_review|tostring)]|join(" ")'; gh api "repos/$R/environments/production" -q '.deployment_branch_policy|"protected="+(.protected_branches|tostring)+" custom="+(.custom_branch_policies|tostring)'; gh api "repos/$R/environments/production/deployment-branch-policies" -q '[.branch_policies[].name]|join(",")'
```

→ expected: `isabellybaldo self-review-blocked=false`; `protected=false custom=true`; `main`. Endpoints confirmed in GitHub's REST docs. The docs do not list `protection_rules[].type` values, so this check selects on `.reviewers`, not a type name.
if not: repo Settings > Environments > New environment `production` > Required reviewers: you; leave "Prevent self-review" off; Deployment branches and tags > Selected > `main`.

### 20. VPS root: print the box's host key line

```bash
cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub
```

→ expected: one line `ssh-ed25519 AAAA...`. Copy it.
if not: `ls /etc/ssh/ssh_host_*.pub`.

### 21. PC Git Bash: scan the box and compare. **STOP** on a mismatch.

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && KH="$HOME/.ssh/isoca_known_hosts.tmp" && /usr/bin/ssh-keyscan -p "$SSH_PORT" -t ed25519 "$VPS_IP" 2>/dev/null | tr -d '\r' >"$KH" && [ "$(wc -l <"$KH")" = 1 ] && read -r -p "paste the line from step 20: " L && [ "$(cut -d' ' -f2- "$KH")" = "$L" ] && echo MATCH || echo MISMATCH
```

→ expected: `MATCH`
if not: **STOP.** Repeat steps 20 and 21 once; still different means something sits between you and the box.

### 22. PC Git Bash: the 4 secrets, from files, in `production` only; then delete the local key

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && R=isabellybaldo/isoca-play && K="$HOME/.ssh/isoca_play" && KH="$HOME/.ssh/isoca_known_hosts.tmp" && tr -d '\r' <"$K" | gh secret set DEPLOY_SSH_KEY -e production -R "$R" && printf '%s' "$VPS_IP" | gh secret set DEPLOY_HOST -e production -R "$R" && printf '%s' "$SSH_PORT" | gh secret set DEPLOY_PORT -e production -R "$R" && gh secret set DEPLOY_KNOWN_HOSTS -e production -R "$R" <"$KH" && echo "production: $(gh secret list -e production -R "$R" | cut -f1 | sort | tr '\n' ' ')" && echo "repository: $(gh secret list -R "$R" | wc -l)" && rm -f "$K" "$K.pub" "$KH"; ls ~/.ssh | grep -c -E 'isoca_play|isoca_known_hosts'
```

→ expected: `production: DEPLOY_HOST DEPLOY_KNOWN_HOSTS DEPLOY_PORT DEPLOY_SSH_KEY`, `repository: 0`, `0`.
if not: one missing: fix and repeat; the local key stays until all four are in. To rotate later: new pair, replace the `--only-play` line, repeat this step.

### 23. PC Git Bash: isoca-play: fork PRs need approval, read-only token, secret scanning, alerts

```bash
R=isabellybaldo/isoca-play; gh api -X PUT "repos/$R/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors; gh api -X PUT "repos/$R/actions/permissions/workflow" --input - <<<'{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'; gh api -X PATCH "repos/$R" --input - >/dev/null <<<'{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; gh api -X PUT "repos/$R/vulnerability-alerts"; gh api "repos/$R/actions/permissions/fork-pr-contributor-approval" -q .approval_policy; gh api "repos/$R/actions/permissions/workflow" -q '[.default_workflow_permissions,(.can_approve_pull_request_reviews|tostring)]|join(" ")'; gh api "repos/$R" -q '[.security_and_analysis.secret_scanning.status,.security_and_analysis.secret_scanning_push_protection.status]|join(" ")'; gh api -i "repos/$R/vulnerability-alerts" | head -n 1
```

→ expected: `all_external_contributors`; `read false`; `enabled enabled`; `HTTP/2.0 204 ...`. All endpoints confirmed in GitHub's REST docs.
if not: repo Settings > Actions > General: Fork pull request workflows > "Require approval for all external contributors"; Workflow permissions > "Read repository contents and packages", "Allow GitHub Actions to create and approve pull requests" off. Settings > Advanced Security: secret scanning, push protection, Dependabot alerts on.

### 24. PC Git Bash: isoca-play's ruleset on main: list first, then create or update

The required check `checks` is the job name in isoca-play's `.github/workflows/ci.yml`.

```bash
R=isabellybaldo/isoca-play; gh api "repos/$R/rulesets" -q '.[]|[.id,.name,.target,.enforcement]|@tsv'; N=$(gh api "repos/$R/rulesets" -q '[.[]|select(.target=="branch")]|length'); if [ "$N" -gt 1 ]; then echo "MORE THAN ONE: read them"; else if [ "$N" = 1 ]; then ID=$(gh api "repos/$R/rulesets" -q '.[]|select(.target=="branch")|.id'); NAME=$(gh api "repos/$R/rulesets/$ID" -q .name); M="-X PUT repos/$R/rulesets/$ID"; else NAME=protect-main; M="-X POST repos/$R/rulesets"; fi; gh api $M --input - >/dev/null <<EOF
{"name":"$NAME","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"checks"}]}},{"type":"deletion"},{"type":"non_fast_forward"}]}
EOF
fi; gh api "repos/$R/rules/branches/main" -q '[.[].type]|sort|join(",")'; gh api "repos/$R/rules/branches/main" -q '.[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'; gh api "repos/$R/rules/branches/main" -q '.[]|select(.type=="pull_request")|.parameters.required_approving_review_count'; ID=$(gh api "repos/$R/rulesets" -q '.[]|select(.target=="branch")|.id'); gh api "repos/$R/rulesets/$ID" -q '"bypass "+(.bypass_actors|length|tostring)+" "+.enforcement'
```

→ expected: any existing ruleset listed first, then `deletion,non_fast_forward,pull_request,required_status_checks`; `checks`; `0`; `bypass 0 active`. Safe to repeat. Endpoints confirmed in GitHub's REST docs.
if not: `MORE THAN ONE`: **STOP**, read them in Settings > Rules > Rulesets and keep one. By hand: Settings > Rules > Rulesets > New branch ruleset, target `main`, Active, no bypass: Restrict deletions, Block force pushes, Require a pull request (0 approvals), Require status checks > `checks`.

## Merge isoca-infra first: the route

### 25. PC Git Bash: DNS once more, merge only if good, then the edge config arrives

Merging makes Traefik ask Let's Encrypt for the name (5 failed validations per host per hour).

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a; I=isabellybaldo/isoca-infra; GOOD=1; for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do [ "$(curl -s -H 'accept: application/dns-json' "$u?name=play.isoca.space&type=A" | grep -cE "\"data\": ?\"$VPS_IP\"")" = 1 ] || GOOD=0; [ "$(curl -s -H 'accept: application/dns-json' "$u?name=play.isoca.space&type=AAAA" | grep -cE '"Answer":.*"type": ?28')" = 0 ] || GOOD=0; done; if [ "$GOOD" = 1 ]; then echo dns-ok; gh pr merge play -R "$I" --merge && sleep 5 && SHA=$(gh api "repos/$I/commits/main" -q .sha) && until ID=$(gh run list -R "$I" -w edge-config.yml --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); [ -n "$ID" ]; do sleep 5; done; gh run watch "$ID" -R "$I" --exit-status >/dev/null; gh run view "$ID" -R "$I" --log | grep -oE 'edge config [0-9]+ files' | tail -n 1; else echo DNS-NOT-READY; fi
```

→ expected: `dns-ok`, the merge, then `edge config 4 files`.
if not: **STOP.** `DNS-NOT-READY`: nothing was merged; step 5. A red run: `gh run view "$ID" -R "$I" --log-failed | tail -30`. To take the route back: a revert pull request, merged, sends the old files.

### 26. PC Git Bash: the certificate, and the old sites. **STOP** if radar or portfolio moved.

```bash
sleep 60; curl -sv -o /dev/null -w "play login %{http_code}\n" https://play.isoca.space/login 2>&1 | grep -iE "issuer:|SSL certificate verify|^play login"; for u in https://radar.isoca.space/ https://radar.isoca.space/math https://radar.isoca.space/sweet https://isoca.space/ https://www.isoca.space/ https://isabellybaldo.github.io/; do curl -s -o /dev/null -w "%{http_code} $u\n" "$u"; done
```

→ expected: an `issuer:` line naming Let's Encrypt; `SSL certificate verify ok.`; `play login 502` (no container yet); `200`, `200`, `200`, `302`, `302`, `200`.
if not: **STOP.** Never restart Traefik in a loop. In window A: `docker compose -f /srv/isoca-infra/edge/compose.yml logs --since 10m traefik 2>&1 | grep -iE 'acme|certificate|play' | cut -c1-200 | tail -n 20`. Timeout or refused: firewall. NXDOMAIN or a wrong address: DNS. Fix, wait 10 minutes, repeat once. Radar or portfolio wrong: revert the pull request first.

### 27. VPS root: take main on the box; installed files equal the repo; compose parses

```bash
git -C /srv/isoca-infra pull --ff-only && git -C /srv/isoca-infra log --oneline -1 && cd /srv/isoca-infra && cmp box/site-deploy /usr/local/bin/site-deploy && cmp box/play-apply /usr/local/bin/play-apply && for u in path service timer; do cmp "box/play-apply.$u" "/etc/systemd/system/play-apply.$u"; done; echo "cmp done"; PLAY_DIGEST=sha256:$(printf '0%.0s' {1..64}) docker compose -f play/compose.yml config -q && echo compose-ok; stat -c '%a %n' play play/compose.yml; ls /srv/edge/dynamic; cd
```

→ expected: the merge commit; `cmp done` with no `differ` line; `compose-ok`; `755`, `644`; `common.yml isoca.yml play.yml radar.yml`. No nginx restart is needed: this merge did not change its config.
if not: a `differ` line: main moved past your commit: install that file again as in step 9 or 14. Do not merge isoca-play until this is clean.

## Merge isoca-play second: the first release

### 28. PC Git Bash: push `design-check`, open the pull request, wait for `checks`

```bash
cd ~/PycharmProjects/isoca-play && R=isabellybaldo/isoca-play && git push origin refs/heads/design-check:refs/heads/design-check && gh pr create -R "$R" --base main --head design-check --title "The first playtest" --body "Runbook 3 in isoca-infra says when to merge."; sleep 15; gh pr checks design-check -R "$R" --watch
```

→ expected: a pull request URL, then `checks` passing (up to 20 minutes). Nothing deploys.
if not: **STOP.** Read the failing step, fix on the branch. A required check named anything else: read `gh pr checks`, then fix step 24.

### 29. PC Git Bash: merge; the release builds and publishes, then waits for you

```bash
R=isabellybaldo/isoca-play; gh pr merge design-check -R "$R" --merge && sleep 5 && SHA=$(gh api "repos/$R/commits/main" -q .sha) && echo "$SHA" && until ID=$(gh run list -R "$R" -w release.yml --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); [ -n "$ID" ]; do sleep 5; done; echo "run $ID"; until C=$(gh run view "$ID" -R "$R" --json jobs -q '.jobs[]|select(.name=="publish")|.conclusion'); [ -n "$C" ]; do sleep 15; done; echo "publish: $C"; gh run view "$ID" -R "$R" --json jobs -q '.jobs[]|select(.name=="deploy")|.status'
```

→ expected: the main commit, `run <id>`, up to 30 minutes later `publish: success`, then `waiting` (or `queued`; the run page shows Review deployments). Do not approve yet.
if not: **STOP.** `publish: failure` or `skipped`: `gh run view "$ID" -R "$R" --log-failed | tail -40`, fix through a new pull request. Nothing reached the box.

### 30. GitHub browser: make the package public. This cannot be undone.

```text
github.com/isabellybaldo?tab=packages > isoca-play > Package settings
Danger Zone > Change visibility > Public > type isoca-play > confirm.
Manage Actions access: isabellybaldo/isoca-play is listed with role Write or Admin.
```

→ expected: the package page shows Public, and the repo is listed under Manage Actions access. No REST endpoint for this is documented: the page is the way. The code is already public; the image holds no secrets.
if not: the repo is not listed: Add repository > isoca-play > role Write. Without this the next publish can fail with `denied`.

### 31. PC Git Bash: anyone can read it, with no login

```bash
R=isabellybaldo/isoca-play; SHA=$(gh api "repos/$R/commits/main" -q .sha); T=$(curl -fsS "https://ghcr.io/token?scope=repository:$R:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/'); curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "https://ghcr.io/v2/$R/manifests/$SHA"
```

→ expected: `200`. The ghcr.io token route is unconfirmed: it is not in GitHub's REST docs. Fallback: the package page says Public, and in a shell with no login `docker pull ghcr.io/isabellybaldo/isoca-play:<commit>` works.
if not: **STOP.** Do not approve. A failed token request or `401`, `403`: still private; step 30. `404`: the wrong commit; `gh run list -R "$R" -w release.yml -L 3`.

### 32. GitHub browser, then PC Git Bash: approve the deploy, then watch it

```text
isoca-play > Actions > the release run > Review deployments > production > Approve and deploy
```

```bash
R=isabellybaldo/isoca-play; SHA=$(gh api "repos/$R/commits/main" -q .sha); ID=$(gh run list -R "$R" -w release.yml --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); gh run watch "$ID" -R "$R" --exit-status >/dev/null; echo "run exit $?"; gh run view "$ID" -R "$R" --log | grep -oE 'released play sha256:[0-9a-f]{64}|login [0-9]+, version [^ ]+' | tail -n 2; curl -s https://play.isoca.space/healthz; echo; echo "$SHA"
```

→ expected: `run exit 0`, `released play sha256:...`, `login 200, version <commit>`, then `{"version":"<commit>"}` and the same commit.
if not: the first release may fail: the fix is a re-run, and the box does not retry alone. In window A: `cat /srv/play/state/last-result; journalctl -u play-apply -n 30`. `the pull failed`: steps 30 and 31. Then `gh run rerun "$ID" -R "$R" --failed` and approve again. A failed first release leaves nothing running and clears `desired-image`, so the same digest counts as new. Use `--failed`, not a whole re-run: it keeps the published digest. `refused:` is the box's own reason. `not the head of main` in the log: a newer commit exists; re-run that one.

### 33. VPS root: the box's own view, the first real run of the path unit. **STOP** if not healthy.

```bash
cat /srv/play/state/last-result; ls -A /srv/play/state; cat /srv/play/image.env; docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml ps --format '{{.Service}} {{.Status}} ports=[{{.Ports}}]'; journalctl -u play-apply --since "20 min ago" --no-pager | grep -ciE 'failed|error'; stat -c '%u %a %n' /srv/play/data /srv/play/data/play.db; systemctl is-active play-apply.path play-apply.timer; docker compose -f /srv/isoca-infra/edge/compose.yml ps --format '{{.Service}} {{.Status}}'
```

→ expected: `ok sha256:... <time>`; `applied-image`, `desired-image`, `last-result`; no `previous-image`; `PLAY_DIGEST=sha256:...` the same; `play Up ... (healthy) ports=[8000/tcp]` or no ports (nothing mapped to the host, no `0.0.0.0:`); `0`; `10001 700 /srv/play/data` and `10001 ... play.db`; `active`, `active`; nginx healthy and traefik Up.
if not: **STOP.** A `0.0.0.0:` in ports: the wrong compose file. `permission denied` on `/data`: `chown 10001:10001 /srv/play/data`. Logs: `docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml logs --tail 50 play`.

### 34. VPS root: set the password (typed at the prompt only, so it reaches no shell history)

```bash
docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml exec play isoca-play set-password
```

→ expected: `New password:`, `Again:`, nothing echoed, then `Password set; all sessions ended`. At least 12 characters; save it in your password manager first.
if not: `The two passwords differ` or `Use at least 12`: nothing changed, repeat. No terminal: use window A from step 6. Never pass it as an argument or `echo` it. Same command to change it later.

## Checks on the real site

### 35. PC Git Bash: nothing but the login page without a session; the headers through Traefik

```bash
B=https://play.isoca.space; for p in / /sw.js /assets/x.js /mahjong /login /login.css /healthz /api/save/sudoku; do curl -s -o /dev/null -w "%{http_code} %{redirect_url} $p\n" "$B$p"; done; curl -sI "$B/login" | grep -iE '^(strict-transport-security|content-security-policy|x-content-type-options|x-frame-options|referrer-policy|cache-control)' | cut -c1-260; curl -sI http://play.isoca.space/login | grep -iE '^(HTTP|location)'; curl -s -o /dev/null -w "logout no session %{http_code}\n" -X POST -H "Origin: $B" "$B/logout"; curl -s -o /dev/null -w "logout other origin %{http_code}\n" -X POST -H "Origin: https://example.com" "$B/logout"
```

→ expected: `302 https://play.isoca.space/login` for `/`, `/sw.js`, `/assets/x.js`, `/mahjong`; `200` for `/login`, `/login.css`, `/healthz`; `401` for `/api/save/sudoku`. Then `strict-transport-security: max-age=31536000`; `content-security-policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`; `x-content-type-options: nosniff`; `x-frame-options: DENY`; `referrer-policy: same-origin`; `cache-control: no-store`. Then `HTTP/1.1 308` (or `301`) with `location: https://play.isoca.space/login`. Then `logout no session 302`, `logout other origin 403`.
if not: **STOP** on a `200` for anything but those three: game code or data is open. In window A: `docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml stop play`, then read.

### 36. PC Git Bash: cookie flags, and `Clear-Site-Data` through Traefik

```bash
B=https://play.isoca.space; J=$(mktemp); read -rs -p "password: " P; echo; printf '%s' "$P" | curl -s -o /dev/null -D - -c "$J" -H "Origin: $B" --data-urlencode password@- "$B/login" | grep -iE '^(HTTP|location|set-cookie)' | sed -E 's/(__Host-[^=]*=)[^;]+/\1<hidden>/'; unset P; curl -s -o /dev/null -w "signed in / %{http_code}\n" -b "$J" "$B/"; curl -s -o /dev/null -D - -b "$J" -c "$J" -X POST -H "Origin: $B" "$B/logout" | grep -iE '^(HTTP|location|clear-site-data|cache-control|set-cookie)' | sed -E 's/(__Host-[^=]*=)[^;]+/\1<hidden>/'; curl -s -o /dev/null -w "after log out / %{http_code}\n" -b "$J" "$B/"; rm -f "$J"
```

→ expected: login: `HTTP/2 303`, `location: /#logged-in`, `set-cookie: __Host-...=<hidden>; Max-Age=...; Path=/; Secure; HttpOnly; SameSite=Strict`. `signed in / 200`. Log out: `HTTP/2 303`, `location: /login`, `cache-control: no-store`, `clear-site-data: "cache", "storage"`, a `set-cookie` with `Max-Age=0`. `after log out / 302`.
if not: **STOP** with no `clear-site-data`: a middleware removes it; compare `edge/dynamic/play.yml` with `/srv/edge/dynamic/play.yml`. A flag missing from the cookie: **STOP**. `401`: wrong password; step 34.

### 37. PC Git Bash: one wrong password with a forged address; print your real one

```bash
B=https://play.isoca.space; curl -4 -s -o /dev/null -w "wrong password %{http_code}\n" -H "Origin: $B" -H 'X-Forwarded-For: 203.0.113.99' --data-urlencode "password=not-the-password" "$B/login"; curl -4 -s https://api.ipify.org; echo
```

→ expected: `wrong password 401`, then your public address. Copy it. Not saved anywhere.
if not: `429` or a 401 with `Too many tries`: step 39, then repeat.

### 38. VPS root: the app recorded your real address, not the forged one and not Docker's. **STOP** if not: the login limit depends on it.

```bash
read -r -p "address from step 37: " ME; docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml exec -T play python -c 'import os,sys; from isoca_play import db; c=db.connect(os.environ["DB_PATH"]); me=sys.argv[1]; print("mine", c.execute("SELECT COUNT(*) FROM failure WHERE ip=?",(me,)).fetchone()[0]); print("forged", c.execute("SELECT COUNT(*) FROM failure WHERE ip=?",("203.0.113.99",)).fetchone()[0]); print("docker", c.execute("SELECT COUNT(*) FROM failure WHERE ip LIKE ? OR ip LIKE ?",("172.%","10.%")).fetchone()[0]); print("other", c.execute("SELECT COUNT(*) FROM failure WHERE ip<>?",(me,)).fetchone()[0]); c.close()' "$ME"
```

→ expected: `mine 1`, `forged 0`, `docker 0`, `other 0` (a stranger's try can raise `other` only).
if not: **STOP**, do not share the site. `forged 1`: Traefik trusts client headers: check `edge/traefik.yml` has no `trustedIPs`. `docker` above 0: every visitor shares one block; check no AAAA record exists and that 80 and 443 are published by Docker (runbook 2 step 16).

### 39. VPS root: recovery: clear the `failure` table (use this any time the login blocks you)

```bash
docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml exec -T play python -c 'import os; from isoca_play import db; c=db.connect(os.environ["DB_PATH"]); print("cleared", c.execute("DELETE FROM failure").rowcount, "left", c.execute("SELECT COUNT(*) FROM failure").fetchone()[0]); c.close()'
```

→ expected: `cleared 1 left 0` here (any number before `left 0` later). It touches only failed tries: not the password, sessions or saves. A restart does not clear them.
if not: `no such service` or `not running`: step 33's `logs` line.

### 40. PC Git Bash: the block after 5 failures

```bash
B=https://play.isoca.space; for i in 1 2 3 4 5 6; do curl -4 -s -o /tmp/play-try.html -w "$i %{http_code} " -H "Origin: $B" --data-urlencode "password=not-the-password" "$B/login"; grep -c "Too many tries" /tmp/play-try.html; done; rm -f /tmp/play-try.html
```

→ expected: `1 401 0` to `5 401 0`, then `6 401 1`. You are now blocked for 15 minutes from this address.
if not: **STOP** if line 6 still ends in `0`: the limit is not working. A `429` line (`Busy right now`): more than 20 failures site-wide; step 39, repeat.

### 41. VPS root, then Your Chrome: clear it again; log in; no CSP errors

```bash
docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml exec -T play python -c 'import os; from isoca_play import db; c=db.connect(os.environ["DB_PATH"]); print("cleared", c.execute("DELETE FROM failure").rowcount, "left", c.execute("SELECT COUNT(*) FROM failure").fetchone()[0]); c.close()'
```

```text
Chrome: https://play.isoca.space, DevTools > Console open. Log in. Open mahjong, make a move. Open sudoku, enter a number.
Reload each. Log out.
```

→ expected: `cleared 5 left 0`; login works at once; both games draw, save and resume after the reload; log out lands on the login page; no red line in the console, in particular no `Content Security Policy`. First run of the real app under this policy.
if not: **STOP.** Write down the page and the first console line. The fix is a pull request; `edge/dynamic/play.yml` holds the policy.

## Rollback drill

`rollback play` is refused until a second release has succeeded. Rollback is a toggle: only one previous digest is kept, so a second rollback returns to the newer one.

### 42. PC Git Bash: a second release from a new commit (a new commit, so the version changes)

```bash
cd ~/PycharmProjects/isoca-play && R=isabellybaldo/isoca-play && git fetch origin refs/heads/main && git switch -c rollback-drill FETCH_HEAD && git commit --allow-empty -q -m "release: a second digest for the rollback drill" && git push origin refs/heads/rollback-drill:refs/heads/rollback-drill && gh pr create -R "$R" --base main --head rollback-drill --title "A second digest for the rollback drill" --body "Empty commit." ; sleep 15; gh pr checks rollback-drill -R "$R" --watch && gh pr merge rollback-drill -R "$R" --merge && sleep 5 && SHA=$(gh api "repos/$R/commits/main" -q .sha) && until ID=$(gh run list -R "$R" -w release.yml --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); [ -n "$ID" ]; do sleep 5; done; echo "approve run $ID in the browser: Review deployments > production"; gh run watch "$ID" -R "$R" --exit-status >/dev/null; echo "run exit $?"; curl -s https://play.isoca.space/healthz; echo; echo "$SHA"
```

→ expected: `checks` pass, the merge, your approval click, `run exit 0`, and `/healthz` showing the same new commit. A direct push to main would be refused: that is the ruleset working.
if not: publish `denied`: step 30's Manage Actions access, then `gh run rerun "$ID" -R "$R" --failed`. A failed apply on the box: `cat /srv/play/state/last-result` in window A. A bad image means about 60 seconds down, then back on the old digest.

### 43. VPS root: two different digests on record

```bash
cat /srv/play/state/last-result; echo "applied $(cut -c1-19 /srv/play/state/applied-image)"; echo "previous $(cut -c1-19 /srv/play/state/previous-image)"; [ "$(cat /srv/play/state/applied-image)" != "$(cat /srv/play/state/previous-image)" ] && echo different
```

→ expected: `ok sha256:... <time>`, two lines, `different`.
if not: `No such file` on `previous-image`: the second run produced the same digest, so nothing changed: the rollback would be refused. Repeat step 42 with another commit.

### 44. PC Git Bash: roll back (approve it in the browser); the version changes

```bash
R=isabellybaldo/isoca-play; BEFORE=$(curl -s https://play.isoca.space/healthz); OLD=$(gh run list -R "$R" -w release.yml -e workflow_dispatch -L 1 --json databaseId -q '.[0].databaseId'); gh workflow run release.yml -R "$R" -f rollback=true && until RID=$(gh run list -R "$R" -w release.yml -e workflow_dispatch -L 1 --json databaseId -q '.[0].databaseId'); [ -n "$RID" ] && [ "$RID" != "$OLD" ]; do sleep 3; done; echo "approve run $RID in the browser: Review deployments > production"; gh run watch "$RID" -R "$R" --exit-status >/dev/null; echo "run exit $?"; gh run view "$RID" -R "$R" --log | grep -oE 'rolled back play|refused: [a-z ]+|login [0-9]+, version [^ ]+, was [^ ]+' | tail -n 2; echo "before $BEFORE"; curl -s https://play.isoca.space/healthz; echo
```

→ expected: `run exit 0`, `rolled back play`, `login 200, version <first commit>, was <second commit>`, and `/healthz` moved to the first commit.
if not: `refused: no previous play release`: step 43. **Known false red:** rolling back to a digest built from the same commit (a whole re-run of a release, not a new commit) leaves the version the same, so the run goes red with `version X, was X` after 2 minutes. Go to step 45: if it shows `ok` and the digests swapped, the rollback worked. Do not start another rollback to clear the red: it toggles back.

### 45. VPS root: the box agrees, the password and saves survived

```bash
cat /srv/play/state/last-result; echo "applied $(cut -c1-19 /srv/play/state/applied-image)"; echo "previous $(cut -c1-19 /srv/play/state/previous-image)"; docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml ps --format '{{.Service}} {{.Status}}'; docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml exec -T play python -c 'import os; from isoca_play import db; c=db.connect(os.environ["DB_PATH"]); print("accounts", c.execute("SELECT COUNT(*) FROM account").fetchone()[0], "saves", c.execute("SELECT COUNT(*) FROM save").fetchone()[0]); c.close()'; systemctl is-active play-apply.path play-apply.timer
```

→ expected: `ok sha256:... <time>`; `applied` and `previous` are the two values of step 43, swapped; `play Up ... (healthy)`; `accounts 1 saves 2` (or the number of games you opened in step 41); `active`, `active`.
if not: **STOP.** `failed ...`: it reads what happened and the box went back. `accounts 0`: the data mount is wrong; do not go on.

### 46. PC Git Bash: roll back again, to the newest (approve it in the browser)

```bash
R=isabellybaldo/isoca-play; SHA=$(gh api "repos/$R/commits/main" -q .sha); OLD=$(gh run list -R "$R" -w release.yml -e workflow_dispatch -L 1 --json databaseId -q '.[0].databaseId'); gh workflow run release.yml -R "$R" -f rollback=true && until RID=$(gh run list -R "$R" -w release.yml -e workflow_dispatch -L 1 --json databaseId -q '.[0].databaseId'); [ -n "$RID" ] && [ "$RID" != "$OLD" ]; do sleep 3; done; echo "approve run $RID in the browser: Review deployments > production"; gh run watch "$RID" -R "$R" --exit-status >/dev/null; echo "run exit $?"; curl -s https://play.isoca.space/healthz; echo; echo "$SHA"
```

→ expected: `run exit 0`, and `/healthz` shows the same commit as the last line.
if not: `/healthz` shows the older commit: repeat this step once and read `last-result` in window A first.

## Close the box work

### 47. VPS root: disk use

```bash
df -h / | tail -n 1; docker system df; docker images --digests --format '{{.Repository}} {{.Digest}} {{.Size}}' ghcr.io/isabellybaldo/isoca-play | cut -c1-70; du -sh /srv/play/data /srv/sites /srv/edge/acme; journalctl --disk-usage
```

→ expected: `Use%` under 80; two digests of the image (the next good release prunes older ones); `/srv/play/data` a few MB at most.
if not: more than two digests after the next release: `journalctl -u play-apply | grep -i 'image rm'`. Above 80%: find it with `du -xh / --max-depth=2 | sort -h | tail`. Do not run a blanket `docker system prune` while reading this: remove only what you can name.

### 48. PC Git Bash: radar and portfolio, one last time

```bash
for u in https://radar.isoca.space/ https://radar.isoca.space/math https://radar.isoca.space/sweet https://isoca.space/ https://www.isoca.space/ https://isabellybaldo.github.io/; do curl -s -o /dev/null -w "%{http_code} $u\n" "$u"; done
```

→ expected: `200`, `200`, `200`, `302`, `302`, `200`.
if not: **STOP.** Runbook 2, "If something breaks later". Keep the `site-deploy.before-play` file until this is good.

### 49. VPS root: remove the old site-deploy copy, leave window A

```bash
rm -f /usr/local/bin/site-deploy.before-play; ls /usr/local/bin | grep -E 'site-deploy|play-apply'; exit
```

→ expected: `play-apply`, `site-deploy`, then window A closes back to your PC.
if not: `ls -l /usr/local/bin`.

## The phone

### 50. Phone: install

```text
Open https://play.isoca.space in the phone's browser. Log in.
iPhone: Share > Add to Home Screen.   Android: menu > Add to Home screen.
Open the site from the new icon. If it asks for the login again, log in: it has its own storage.
Note the phone model and system version: iPhone: Settings > General > About.
```

→ expected: an icon on the home screen that opens the login or the game. The site has no web manifest, by design, so it may open in a browser window: use that same way in for steps 51 and 52.
if not: no such menu item: use a normal browser tab for the next steps and note it.

### 51. Phone: offline reopen

```text
From the icon: open mahjong and make a move. Open sudoku and enter a number. Wait 10 seconds online.
Airplane mode on. Close the app fully (swipe it away). Open the icon again.
Play a move. Look at the new game button and the marker. Close it fully again, reopen.
Airplane mode off. Reopen. Make a move, wait 10 seconds. Open the site on the PC.
```

→ expected: offline, both games open from the last save and can be played; new game is disabled with a short note; a marker says progress is not being saved. Moves made offline and then closed are lost (by design). Back online, the new move saves and the PC shows it.
if not: note what showed and the step. Blank page or the browser's offline page: **STOP** the playtest and report it; the worker did not take over.

### 52. Phone: log out timing and what it leaves

```text
Online, from the icon, signed in. Stopwatch: tap Log out, stop when the login page shows. Do it 3 times, logging in between.
After the last one: airplane mode on, close fully, reopen the icon. Airplane mode off, reopen.
```

→ expected: each log out under about 5 seconds (the page waits at most 3 seconds for the server, then says if it could not confirm). Offline after log out: no game and no save, only the browser's offline page or the login. Online: the login page.
if not: write down the three times. A game opens offline after log out: **STOP** sharing the phone with anyone; report it, with the phone and system version.

### 53. Phone: iOS Safari and `Clear-Site-Data`

```text
iPhone only. Read the iOS version from step 50.
```

→ expected: iOS 17.0 or newer. caniuse lists the header and its `"cache"` directive as supported on Safari for iOS from 17.0. Support for `"storage"` was not confirmed from those pages, and no iOS run has happened. So step 52's offline result on the phone is the real test.
if not: iOS 16 or older ignores the header. The page's own script still removes the worker, caches and saves, and the server ends the session. Hashed game code stays in the HTTP cache until evicted; it holds no secret and cannot open without a worker and a session. Accepted, as long as step 52 passes.

## If something breaks later

Blocked at the login: step 39.

Forgot the password: step 34, in a root shell (step 6).

Roll back (asks for your approval; a toggle between the last two digests):

```bash
gh workflow run release.yml -R isabellybaldo/isoca-play -f rollback=true
```

The workflow stops, red and without rolling back, if `/healthz` stays unreadable for a minute first. For a site that is down, roll back in a root shell (step 6): `runuser -u deploy -- env SSH_ORIGINAL_COMMAND="rollback play" /usr/local/bin/site-deploy --only-play </dev/null`, then `cat /srv/play/state/last-result` after a minute.

Roll forward: a pull request merged to main. Every deploy and rollback waits at Review deployments.

On the box, as root:

```bash
cat /srv/play/state/last-result
journalctl -u play-apply -n 50
docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml logs --tail 100 play
```

Take the play key away; old key and radar are unaffected:

```bash
sed -i '/--only-play/d' /home/deploy/.ssh/authorized_keys
```

Take the site down, keeping its data: `docker compose --env-file /srv/play/image.env -f /srv/isoca-infra/play/compose.yml stop play`.

A digest that is up but could not be recorded repeats pull and up every minute until the disk is fixed: step 47 first. A digest that did not come up and could not be restored is not recreated: `/run/play-apply.no-retry` names it, and the restore finishes by itself once the disk has room.
