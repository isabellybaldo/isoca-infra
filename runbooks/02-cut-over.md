# Runbook 2: first deploy, then the DNS cut-over

Owner-run, after runbook 1 ended clean. Every step is one command block, then `→ expected:`, then `if not:`. **STOP** means: do not go on until it is fixed.
Values come from `local.env` (`VPS_IP`, `SSH_PORT`, `ADMIN`). Commands that need the box run from the PC over ssh; nothing is typed on the box except through `ssh -t ... sudo`.

Open new Git Bash windows after runbook 1 step 8 (they have the terminal setting that ssh -t, sudo and passphrase prompts need).

Where a step runs: **PC Git Bash** (blocks put Windows OpenSSH first on PATH, as in runbook 1), **Hostinger browser**, **GitHub browser**.

The order protects you: the new site is proven on `new.isoca.space` first; only then do `radar` and `isoca.space` move.
Let's Encrypt allows 5 failed validations per host per hour. Staging is not used. Whenever a certificate fails, read the Traefik log (the step says how) before retrying; never restart Traefik in a loop.

## Prepare DNS

### 1. Hostinger browser: save the whole DNS zone before touching it

```text
Hostinger panel > Domains > isoca.space > DNS / Nameservers > DNS records:
use the export / download option for the zone file; if there is none, screenshot every record.
Save it OUTSIDE the isoca-infra folder (it holds the box's address). Note the TTL now on @, www, radar.
```

→ expected: a zone file or screenshots that show every record (A, AAAA, CNAME, MX, TXT), and the three TTL values written down.
if not: **STOP.** No export means no way back; list the records by hand into a note.

### 2. Hostinger browser: lower the TTL to 300 on `@`, `www`, `radar`

```text
DNS records: edit the records for @, www and radar (A, or CNAME for www): TTL = 300. Change nothing else.
```

→ expected: the three records show TTL 300.
if not: the panel refuses 300 -> use its lowest TTL, write it down; step 4 then expects that value or less.

### 3. Hostinger browser: add `new.isoca.space`

```text
DNS records > Add record: Type A, Name new, Points to = VPS_IP from local.env, TTL 300.
```

→ expected: a new A record `new`, TTL 300.
if not: wrong name (`new.isoca.space.isoca.space`) -> the Name field takes `new` only.

### 4. PC Git Bash: wait one old TTL; TTLs are low and `new.isoca.space` resolves to the box. **STOP** if not.

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a
for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do for h in isoca.space www.isoca.space radar.isoca.space; do echo "$h $(curl -s -H 'accept: application/dns-json' "$u?name=$h&type=A" | grep -oE '"TTL": ?[0-9]+' | head -1)"; done; done
for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do echo "new.isoca.space $(curl -s -H 'accept: application/dns-json' "$u?name=new.isoca.space&type=A" | grep -cE "\"data\": ?\"$VPS_IP\"")"; done
```

→ expected: six TTL lines, each `"TTL":` with 300 or less (or the lowest value you noted in step 2), then `new.isoca.space 1` twice.
if not: **STOP.** A bigger TTL is the old TTL still counting down: wait that long and repeat. `new.isoca.space 0` -> wait 5 minutes and repeat; still 0 after 15 -> step 3 (name, address) in the panel. Do not start Traefik's certificate request (step 5) before both lines say 1.

### 5. PC Git Bash: Traefik asks Let's Encrypt for the new name's certificate

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo docker compose -f /srv/isoca-infra/edge/compose.yml restart traefik && sleep 30 && sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs --since 2m traefik 2>&1 | grep -iE "acme|certificate" | cut -c1-200 | tail -n 10; sudo grep -oE "\"main\": *\"[^\"]+\"" /srv/edge/acme/acme.json | sort -u'
```

→ expected: after the sudo password: errors naming `radar.isoca.space`, `isoca.space`, `www.isoca.space` are normal (DNS still elsewhere); NONE for `new.isoca.space`; the last lines list the stored certificates and include `"main": "new.isoca.space"`.
if not: no `new.isoca.space` in the list -> read the log lines (`logs traefik | grep -i acme`): "connection refused" or "timeout" = firewall (ufw or the Hostinger panel; ports 80 and 443), "NXDOMAIN" or wrong address = DNS (step 4). Fix the cause, wait 10 minutes, then repeat this step once.

## First deploy

### 6. PC Git Bash: point the smoke check at the test name

```bash
gh variable set DEPLOY_URL -R isabellybaldo/isoca-radar -b https://new.isoca.space/ && gh variable list -R isabellybaldo/isoca-radar | cut -f1,2
```

→ expected: `DEPLOY_URL	https://new.isoca.space/`
if not: `gh auth status`; you need admin on isoca-radar.

### 7. PC Git Bash: push the branch and open the pull request that adds the deploy job to isoca-radar

```bash
cd ~/PycharmProjects/cute-trading && git push origin plan-3 && gh pr create -R isabellybaldo/isoca-radar --fill
```

→ expected: a pull request URL on github.com/isabellybaldo/isoca-radar; its checks start.
if not: `git remote -v` must show isoca-radar as `origin`; a push or `gh` error: read it, fix it. The branch name is `plan-3`.

### 8. GitHub browser: merge that pull request

```text
github.com/isabellybaldo/isoca-radar > Pull requests > the PR from the previous step > Merge pull request
(only its merge to main deploys)
```

→ expected: the PR shows Merged; Actions shows a `portfolio` run on `main` starting.
if not: checks failing on the PR -> read them first; do not merge red.

### 9. PC Git Bash: watch the run on the merge commit; its deploy job ends with `deployed radar ...`

```bash
R=isabellybaldo/isoca-radar; SHA=$(gh api repos/$R/commits/main -q .sha); until ID=$(gh run list -R "$R" -w portfolio.yml -b main --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); [ -n "$ID" ]; do sleep 5; done; gh run watch "$ID" -R "$R" --exit-status >/dev/null; gh run view "$ID" -R "$R" --log | grep -oE 'deployed radar [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: one line `deployed radar 2026...Z-<7 hex>` (this takes a few minutes).
if not: nothing printed -> `gh run view "$ID" -R "$R" --log-failed | tail -40`. "did not answer 200" after a successful upload means the site is on the box but `new.isoca.space` is not answering: step 5 and 10. "secret ... is empty or missing" -> runbook 1 step 47. "refused: ..." is the box's own reason.

### 10. PC Git Bash: the pages, headers and certificate on `new.isoca.space`. **STOP** if any line is wrong.

```bash
B=https://new.isoca.space; curl -sI "$B/" | grep -iE '^(HTTP|strict-transport-security|content-security-policy|x-content-type-options)' | cut -c1-90; for p in /math /sweet /frozen/public.json /nope; do curl -s -o /dev/null -w "$p %{http_code} %{content_type}\n" "$B$p"; done; curl -sv -o /dev/null "$B/" 2>&1 | grep -iE "issuer:|SSL certificate verify"
```

→ expected: `HTTP/... 200`, `strict-transport-security: max-age=31536000`, a `content-security-policy: default-src 'none'; ...` line, `x-content-type-options: nosniff`; then `/math 200 text/html`, `/sweet 200 text/html`, `/frozen/public.json 200 application/json`, `/nope 404 ...`; then an `issuer:` line naming `Let's Encrypt` and `SSL certificate verify ok.`
if not: **STOP.** `curl: (60)`, `TRAEFIK DEFAULT CERT` or a verify error: the certificate was not issued; do step 5's log reading and do not restart Traefik again until you know why (5 failures per host per hour). A 301 on `/math` or `/sweet` -> read its `location:` header (`curl -sI`) and stop. 404 where 200 is expected -> `ssh ... ls /srv/sites/radar/current/` shows what was deployed. Roll back with the workflow in "If something breaks later".

### 11. Your Chrome: look at the site

```text
Open https://new.isoca.space/ on desktop and at 360 px wide (DevTools > device toolbar).
Click through the pages. Open DevTools > Console.
```

→ expected: pages render, the WASM part loads, the console shows no red CSP errors.
if not: **STOP.** Write down the page and the first console error; the deploy can be rolled back (see the last section) and DNS has not moved yet.

## Move DNS

### 12. Hostinger browser: list the records of the old tenants that are being dropped. Delete nothing yet.

```text
DNS records: find every record that is not `@`, `www`, `radar`, `new`, MX or TXT (any type).
Compare with the zone export from step 1; write the list down.
```

→ expected: a written list of those records (or "none"), plus anything else you do not recognise.
if not: a record you did not expect, or a name used by something that is still live -> leave it and decide separately.

### 13. Hostinger browser: point the three names at the box, delete the dropped tenants and every AAAA

```text
@, www, radar: Type A, Points to = VPS_IP from local.env, TTL 300. Replace a CNAME on www with an A record.
Delete the records in the step 12 list. Delete any AAAA record for @, www, radar
(Docker's userland proxy hides IPv6 clients' addresses and merges them into one rate-limit bucket).
Leave MX, TXT and everything else alone.
```

→ expected: A records for `@`, `www`, `radar` all point to the box; the dropped tenants are gone; no AAAA records on those three names.
if not: to undo this whole step, re-enter the records from the step 1 export (the old box is gone, so that restores the zone, not the old site).

### 14. PC Git Bash: all three names resolve to the box, with no IPv6 answer. **STOP** on either check.

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a
for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do for h in isoca.space www.isoca.space radar.isoca.space; do echo "A $h $(curl -s -H 'accept: application/dns-json' "$u?name=$h&type=A" | grep -cE "\"data\": ?\"$VPS_IP\"")"; done; done
for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do for h in isoca.space www.isoca.space radar.isoca.space; do echo "AAAA $h $(curl -s -H 'accept: application/dns-json' "$u?name=$h&type=AAAA" | grep -cE '"Answer":.*"type": ?28')"; done; done
```

→ expected: six `A ...` lines ending in `1`, then six `AAAA ...` lines ending in `0`.
if not: **STOP.** An A line with `0` -> wait 5 minutes (TTL 300) and repeat; do not go to step 15 before all six are 1 (Traefik would ask Let's Encrypt too early and burn failed validations). An AAAA line with `1` -> an AAAA record is left in the panel (step 13); delete it, wait 5 minutes, repeat.

### 15. PC Git Bash: Traefik asks Let's Encrypt for the three real names

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo docker compose -f /srv/isoca-infra/edge/compose.yml restart traefik && sleep 40 && sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs --since 2m traefik 2>&1 | grep -iE "unable|error" | cut -c1-200 | tail -n 8; sudo grep -oE "\"main\": *\"[^\"]+\"|\"www[.]isoca[.]space\"" /srv/edge/acme/acme.json | sort -u'
```

→ expected: no "Unable to obtain" lines; the list shows `"main": "isoca.space"`, `"main": "new.isoca.space"`, `"main": "radar.isoca.space"`, and `"www.isoca.space"` (one certificate covers isoca.space and www).
if not: a name is missing -> read its error line (timeout or connection refused = firewall; NXDOMAIN or a wrong address = DNS, repeat step 14). Fix the cause, wait 10 minutes, then repeat this step once. Do not restart in a loop.

### 16. PC Git Bash: Traefik sees the real client address. **STOP** if it does not.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ME=$(curl -4 -s https://api.ipify.org) && curl -4 -s https://radar.isoca.space/ -o /dev/null && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" "sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs traefik | tail -n 40 | grep -c '\"ClientHost\":\"$ME\"'"
```

→ expected: after the sudo password, a number of 1 or more (the access log carries your public address as `ClientHost`).
if not: **STOP.** `0` -> look at what it logs: `... logs traefik | tail -n 5 | grep -o '"ClientHost":"[^"]*"'`. A Docker gateway address (172.x) means every visitor shares one rate-limit bucket: do not announce the site; check there is no AAAA record and that ports 80 and 443 are published by Docker, not proxied.

### 17. PC Git Bash: `radar.isoca.space` answers with a valid certificate; `isoca.space` and `www` send visitors to github.io

```bash
curl -sSI https://radar.isoca.space/ | grep -iE '^(HTTP|strict-transport-security)'; for h in isoca.space www.isoca.space; do curl -sSI "https://$h/foo" | grep -iE '^(HTTP|location)'; done
```

→ expected: `HTTP/... 200` and `strict-transport-security: max-age=31536000`; then for each of the two names `HTTP/... 302` and `location: https://isabellybaldo.github.io/foo`.
if not: `curl: (60)` -> a certificate problem: step 15's log reading. 404 on radar -> `ssh ... ls /srv/sites/radar/current/`. 404 from Traefik on isoca -> `ssh ... ls /srv/edge/dynamic/` must list `isoca.yml`; run the `edge-config` workflow from the Actions tab of isoca-infra.

## Drills and clean-up

### 18. PC Git Bash: remove the test variable (the smoke check now uses radar.isoca.space)

```bash
gh variable delete DEPLOY_URL -R isabellybaldo/isoca-radar && gh variable list -R isabellybaldo/isoca-radar | grep -c DEPLOY_URL
```

→ expected: `0`
if not: `1` -> the variable is still there; repeat the delete.

### 19. PC Git Bash: deploy again (a second release, so a rollback has somewhere to go)

```bash
R=isabellybaldo/isoca-radar; SHA=$(gh api repos/$R/commits/main -q .sha); ID=$(gh run list -R "$R" -w portfolio.yml -b main --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); A=$(gh run view "$ID" -R "$R" --json attempt -q .attempt); gh run rerun "$ID" -R "$R" && until [ "$(gh run view "$ID" -R "$R" --json attempt -q .attempt)" -gt "$A" ]; do sleep 3; done; gh run watch "$ID" -R "$R" --exit-status >/dev/null; gh run view "$ID" -R "$R" --attempt $((A+1)) --log | grep -oE 'deployed radar [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: a `deployed radar ...` line with a newer release id than the one in step 9.
if not: a red smoke check -> `radar.isoca.space` is not answering 200: see "If something breaks later". The same id as step 9 -> `gh run view "$ID" -R "$R" --log | grep deployed` and read the newest line.

### 20. PC Git Bash: the rollback drill, then the site is still up

```bash
I=isabellybaldo/isoca-infra; OLD=$(gh run list -R $I -w rollback.yml -L 1 --json databaseId -q '.[0].databaseId'); gh workflow run rollback.yml -R $I -f site=radar && until RID=$(gh run list -R $I -w rollback.yml -L 1 --json databaseId -q '.[0].databaseId'); [ "$RID" != "$OLD" ]; do sleep 3; done; gh run watch "$RID" -R $I --exit-status >/dev/null; gh run view "$RID" -R $I --log | grep -oE 'rolled back radar to [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1; for p in / /math; do curl -s -o /dev/null -w "$p %{http_code}\n" "https://radar.isoca.space$p"; done
```

→ expected: `rolled back radar to <the step 9 release id>`, then `/ 200` and `/math 200`.
if not: `refused: no older release` -> step 19 did not create a second release. `secret ... missing` for isoca-infra -> runbook 1 step 47. Any other refusal text is the box's own reason. Site not 200 -> run step 21 now; still not 200 -> "If something breaks later".

### 21. PC Git Bash: deploy the latest build again (back to the newest release)

```bash
R=isabellybaldo/isoca-radar; SHA=$(gh api repos/$R/commits/main -q .sha); ID=$(gh run list -R "$R" -w portfolio.yml -b main --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); A=$(gh run view "$ID" -R "$R" --json attempt -q .attempt); gh run rerun "$ID" -R "$R" && until [ "$(gh run view "$ID" -R "$R" --json attempt -q .attempt)" -gt "$A" ]; do sleep 3; done; gh run watch "$ID" -R "$R" --exit-status >/dev/null; gh run view "$ID" -R "$R" --attempt $((A+1)) --log | grep -oE 'deployed radar [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: `deployed radar ...` with a release id newer than the one in step 19.
if not: the same id as step 19 -> `gh run view "$ID" -R "$R" --log | grep deployed` and read the newest line.

### 22. PC Git Bash: remove the test route (`radar-test`, `new.isoca.space`) and commit

```bash
cd ~/PycharmProjects/isoca-infra && git switch main && git pull --ff-only && sed -i '1s/.*/# radar.isoca.space/; 2d' edge/dynamic/radar.yml && sed -i '/^    radar-test:/,/^$/d' edge/dynamic/radar.yml && sed -i 's/ new\.isoca\.space;/;/' edge/nginx/sites.conf && sed -i '/^req "\$NP" new\.isoca\.space/d; /^sreq new\.isoca\.space/,+1d' tests/edge.test.sh && grep -rc 'new\.isoca\.space' edge tests | grep -v ':0$'; bash tests/edge.test.sh | tail -n 2; [ "${PIPESTATUS[0]}" = 0 ] && bash tests/no-secrets.sh && git commit -qam "edge: drop the new.isoca.space test route, DNS has moved" && git log --oneline -1
```

→ expected: no `new.isoca.space` file listed by grep, `N passed, 0 failed` (Docker runs for a few minutes), `no-secrets: clean (...)`, then the new commit.
if not: a test fails -> `git checkout -- .` and look at the failing line before retrying. The sed lines change `radar.yml` (the router and its comment), `sites.conf` (`server_name`) and the three test lines that expected the test host.

### 23. PC Git Bash: push it; the `edge-config` workflow sends the Traefik change to the box

```bash
cd ~/PycharmProjects/isoca-infra && git push origin main && SHA=$(git rev-parse HEAD) && until ID=$(gh run list -R isabellybaldo/isoca-infra -w edge-config.yml --json databaseId,headSha -q ".[]|select(.headSha==\"$SHA\")|.databaseId" | head -1); [ -n "$ID" ]; do sleep 5; done; gh run watch "$ID" -R isabellybaldo/isoca-infra --exit-status >/dev/null; gh run view "$ID" -R isabellybaldo/isoca-infra --log | grep -oE 'edge config [0-9]+ files' | tail -n 1
```

→ expected: `edge config 3 files`
if not: no line -> `gh run view "$ID" -R isabellybaldo/isoca-infra --log-failed | tail -30`. The wait never ends (Ctrl-C) -> the push touched no `edge/dynamic/**` file; step 22 did not change `radar.yml`.

### 24. PC Git Bash: on the box, take the new nginx config and reload nginx

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo git -C /srv/isoca-infra rev-parse --short HEAD && sudo git -C /srv/isoca-infra pull --ff-only && sudo docker compose -f /srv/isoca-infra/edge/compose.yml run --rm --no-deps nginx nginx -t && sudo docker compose -f /srv/isoca-infra/edge/compose.yml restart nginx && sleep 15 && sudo docker compose -f /srv/isoca-infra/edge/compose.yml ps'
```

→ expected: the commit the box had, the pull fast-forwards, `nginx: configuration file ... test is successful`, nginx back to `healthy`, traefik `Up`. (`docker compose up -d` alone would not apply this: compose.yml did not change, only the mounted file.)
if not: `test failed` -> do not restart; `sudo git -C /srv/isoca-infra reset --hard <the commit printed first>` returns the clone to what it had (a later `git pull --ff-only` brings it forward again). nginx `unhealthy` after the restart -> same reset, then `restart nginx` again. (`run --rm --no-deps nginx nginx -t` starts a throwaway container with the new file; a plain `exec` would test the old inode.)

### 25. PC Git Bash: the test name is gone, the real ones work. Then DNS clean-up (next step) ends the cut-over.

```bash
curl -skI https://new.isoca.space/ | head -n 1; for p in https://radar.isoca.space/ https://radar.isoca.space/math https://isoca.space/ https://www.isoca.space/; do curl -s -o /dev/null -w "$p %{http_code}\n" "$p"; done
```

→ expected: `HTTP/... 404`, then `200`, `200`, `302`, `302` for the four addresses.
if not: `new.isoca.space` still 200 -> the edge-config run (step 23) or the nginx restart (step 24) did not apply. `radar` not 200 -> `git revert HEAD`, push, repeat step 24; or the rollback workflow. isoca not 302 -> `ssh ... ls /srv/edge/dynamic/`.

### 26. Hostinger browser: delete the `new` record and raise the TTLs back to 3600

```text
DNS records: delete the A record "new". Set TTL 3600 on @, www, radar.
```

→ expected: no `new` record; the three records show TTL 3600.
if not: a wrong record deleted -> re-enter it from the step 1 export.

## If something breaks later

Roll the site back to the previous release (about 30 seconds; the box keeps the last 5):

```bash
gh workflow run rollback.yml -R isabellybaldo/isoca-infra -f site=radar
```

Roll forward: re-run the last `portfolio` run on `main` (Actions tab, Re-run all jobs) or push a fix to `main`.

Logs (ssh as the admin, then):

```bash
sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs --tail 100 traefik   # certificates, access log (JSON, ClientHost)
sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs --tail 100 nginx
sudo journalctl -u ssh -u fail2ban --since "1 hour ago"                             # logins and bans
sudo fail2ban-client status sshd                                                    # banned addresses
```

The deploy itself logs in GitHub: Actions > the failed run > the "Deploy over SSH" step prints the box's own `refused: ...` text.
A bad edge config: revert the commit that touched `edge/dynamic/`, push to `main`, and the `edge-config` workflow sends the old files back.
Certificates: before any restart of Traefik read the ACME lines in its log; five failed validations per host per hour is the limit.
DNS: the zone export from step 1 is the way back.
