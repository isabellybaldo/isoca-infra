# Runbook 2: first deploy, then the DNS cut-over

Owner-run, after runbook 1 ended clean. Every step is one command block, then `→ expected:`, then `if not:`. **STOP** means: do not go on until it is fixed.
Values come from `local.env` (`VPS_IP`, `SSH_PORT`, `ADMIN`). Commands that need the box run from the PC over ssh; nothing is typed on the box except through `ssh -t ... sudo`.

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
if not: a record has no TTL field -> the panel's default TTL applies; note it and wait that long in step 4.

### 3. Hostinger browser: add `new.isoca.space`

```text
DNS records > Add record: Type A, Name new, Points to = VPS_IP from local.env, TTL 300.
```

→ expected: a new A record `new`, TTL 300.
if not: wrong name (`new.isoca.space.isoca.space`) -> the Name field takes `new` only.

### 4. PC Git Bash: wait one old TTL; the public resolvers must show TTL 300 on all three names

```bash
for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do for h in isoca.space www.isoca.space radar.isoca.space; do echo "$h $(curl -s -H 'accept: application/dns-json' "$u?name=$h&type=A" | grep -oE '"TTL": ?[0-9]+' | head -1)"; done; done
```

→ expected: six lines, each `"TTL":` followed by a number of 300 or less.
if not: a bigger number is the old TTL still counting down; wait that long and repeat. Do not continue until all six are 300 or less.

### 5. PC Git Bash: `new.isoca.space` resolves to the box. **STOP** if not.

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do echo "new.isoca.space $(curl -s -H 'accept: application/dns-json' "$u?name=new.isoca.space&type=A" | grep -cE "\"data\": ?\"$VPS_IP\"")"; done
```

→ expected: `new.isoca.space 1` twice.
if not: **STOP.** `0` -> wait 5 minutes and repeat; still 0 after 15 -> step 3 (name, address) in the panel. Do not start Traefik's certificate request (step 6) before this says 1 on both lines.

### 6. PC Git Bash: Traefik asks Let's Encrypt for the new name's certificate

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo docker compose -f /srv/isoca-infra/edge/compose.yml restart traefik && sleep 30 && sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs --since 2m traefik 2>&1 | grep -iE "acme|certificate" | cut -c1-200 | tail -n 10; sudo grep -oE "\"main\": *\"[^\"]+\"" /srv/edge/acme/acme.json | sort -u'
```

→ expected: after the sudo password: errors naming `radar.isoca.space`, `isoca.space`, `www.isoca.space` are normal (DNS still elsewhere); NONE for `new.isoca.space`; the last lines list the stored certificates and include `"main": "new.isoca.space"`.
if not: no `new.isoca.space` in the list -> read the log lines (`logs traefik | grep -i acme`): "connection refused" or "timeout" = firewall (ufw or the Hostinger panel; ports 80 and 443), "NXDOMAIN" or wrong address = DNS (step 5). Fix the cause, wait 10 minutes, then repeat this step once.

## First deploy

### 7. PC Git Bash: point the smoke check at the test name

```bash
gh variable set DEPLOY_URL -R isabellybaldo/isoca-radar -b https://new.isoca.space/ && gh variable list -R isabellybaldo/isoca-radar | cut -f1,2
```

→ expected: `DEPLOY_URL	https://new.isoca.space/`
if not: `gh auth status`; you need admin on isoca-radar.

### 8. GitHub browser: merge the pull request that adds the deploy job to isoca-radar

```text
github.com/isabellybaldo/isoca-radar > Pull requests > the "deploy the portfolio to radar.isoca.space from main" PR > Merge
(the PR is the one from the plan's task 6; only its merge to main deploys)
```

→ expected: the PR shows Merged; Actions shows a `portfolio` run on `main` starting.
if not: checks failing on the PR -> read them first; do not merge red.

### 9. PC Git Bash: watch the run; its deploy job ends with `deployed radar ...`

```bash
R=isabellybaldo/isoca-radar; sleep 20; ID=$(gh run list -R "$R" -w portfolio.yml -b main -L 1 --json databaseId -q '.[0].databaseId'); gh run watch "$ID" -R "$R" --exit-status >/dev/null; gh run view "$ID" -R "$R" --log | grep -oE 'deployed radar [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: one line `deployed radar 2026...Z-<7 hex>` (this takes a few minutes).
if not: nothing printed -> `gh run view "$ID" -R "$R" --log-failed | tail -40`. "did not answer 200" after a successful upload means the site is up on the box but `new.isoca.space` is not answering: go to step 6 and 10. "secret ... is empty or missing" -> runbook 1 step 53. "refused: ..." is the box's own reason.

### 10. PC Git Bash: the pages and headers on `new.isoca.space`. **STOP** if any line is wrong.

```bash
B=https://new.isoca.space; curl -sI "$B/" | grep -iE '^(HTTP|strict-transport-security|content-security-policy|x-content-type-options)' | cut -c1-90; for p in /math /sweet /frozen/public.json /nope; do curl -s -o /dev/null -w "$p %{http_code} %{content_type}\n" "$B$p"; done
```

→ expected: `HTTP/... 200`, `strict-transport-security: max-age=31536000`, a `content-security-policy: default-src 'none'; ...` line, `x-content-type-options: nosniff`; then `/math 200 text/html`, `/sweet 200 text/html`, `/frozen/public.json 200 application/json`, `/nope 404 ...`.
if not: **STOP.** `curl: (60)` or no output -> step 11. A 301 on `/math` or `/sweet` -> read its `location:` header (`curl -sI`) and stop; the site must answer 200 there. 404 where 200 is expected -> `ssh ... ls /srv/sites/radar/current/` shows what was deployed. Roll back with the workflow in "If something breaks later".

### 11. PC Git Bash: the certificate is a real Let's Encrypt one. **STOP** if not.

```bash
curl -sv -o /dev/null https://new.isoca.space/ 2>&1 | grep -iE "issuer:|SSL certificate verify|expire date"
```

→ expected: an `issuer:` line naming `Let's Encrypt`, and `SSL certificate verify ok.`
if not: **STOP.** `TRAEFIK DEFAULT CERT` or a verify error means the certificate was not issued: do step 6's log reading; do not restart Traefik again until you know why (5 failures per host per hour).

### 12. Your Chrome: look at the site

```text
Open https://new.isoca.space/ on desktop and at 360 px wide (DevTools > device toolbar).
Click through the pages. Open DevTools > Console.
```

→ expected: pages render, the WASM part loads, the console shows no red CSP errors.
if not: **STOP.** Write down the page and the first console error; the deploy can be rolled back (see the last section) and DNS has not moved yet.

## Move DNS

### 13. Hostinger browser: list the records of the tenants that are being dropped. Delete nothing yet.

```text
DNS records: find every record named humor-do-dia, webappexample, apiexample, whoami (any type).
Compare with the zone export from step 1; write the list down.
```

→ expected: a written list of those records (or "none"), plus anything else you do not recognise.
if not: a record you did not expect, or a name used by something that is still live -> leave it and decide separately.

### 14. Hostinger browser: point the three names at the box, delete the dropped tenants and every AAAA

```text
@, www, radar: Type A, Points to = VPS_IP from local.env, TTL 300. Replace a CNAME on www with an A record.
Delete the records in the step 13 list. Delete any AAAA record for @, www, radar
(Docker's userland proxy hides IPv6 clients' addresses and merges them into one rate-limit bucket).
Leave MX, TXT and everything else alone.
```

→ expected: A records for `@`, `www`, `radar` all point to the box; the dropped tenants are gone; no AAAA records on those three names.
if not: to undo this whole step, re-enter the records from the step 1 export (the old box is gone, so that restores the zone, not the old site).

### 15. PC Git Bash: all three names resolve to the box. **STOP** if not.

```bash
cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do for h in isoca.space www.isoca.space radar.isoca.space; do echo "$h $(curl -s -H 'accept: application/dns-json' "$u?name=$h&type=A" | grep -cE "\"data\": ?\"$VPS_IP\"")"; done; done
```

→ expected: six lines, each ending in `1`.
if not: **STOP.** `0` -> wait 5 minutes (TTL 300) and repeat. Do not go to step 17 before all six are 1: Traefik would ask Let's Encrypt too early and burn failed validations.

### 16. PC Git Bash: no IPv6 answer for the three names. **STOP** if there is one.

```bash
for u in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do for h in isoca.space www.isoca.space radar.isoca.space; do echo "$h $(curl -s -H 'accept: application/dns-json' "$u?name=$h&type=AAAA" | grep -cE '"type": ?28')"; done; done
```

→ expected: six lines, each ending in `0`.
if not: **STOP.** `1` -> an AAAA record is left in the panel (step 14); delete it, wait 5 minutes, repeat.

### 17. PC Git Bash: Traefik asks Let's Encrypt for the three real names

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo docker compose -f /srv/isoca-infra/edge/compose.yml restart traefik && sleep 40 && sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs --since 2m traefik 2>&1 | grep -iE "unable|error" | cut -c1-200 | tail -n 8; sudo grep -oE "\"main\": *\"[^\"]+\"" /srv/edge/acme/acme.json | sort -u'
```

→ expected: no "Unable to obtain" lines; the list ends with four names: `isoca.space`, `new.isoca.space`, `radar.isoca.space`, `www.isoca.space`.
if not: a name is missing -> read its error line (timeout or connection refused = firewall; NXDOMAIN or a wrong address = DNS, repeat step 15). Fix the cause, wait 10 minutes, then repeat this step once. Do not restart in a loop.

### 18. PC Git Bash: Traefik sees the real client address. **STOP** if it does not.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ME=$(curl -4 -s https://api.ipify.org) && curl -4 -s https://radar.isoca.space/ -o /dev/null && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" "sudo docker compose -f /srv/isoca-infra/edge/compose.yml logs traefik | tail -n 40 | grep -c '\"ClientHost\":\"$ME\"'"
```

→ expected: after the sudo password, a number of 1 or more (the access log carries your public address as `ClientHost`).
if not: **STOP.** `0` -> look at what it logs: `... logs traefik | tail -n 5 | grep -o '"ClientHost":"[^"]*"'`. A Docker gateway address (172.x) means every visitor shares one rate-limit bucket: do not announce the site; check there is no AAAA record and that ports 80 and 443 are published by Docker, not proxied.

### 19. PC Git Bash: `radar.isoca.space` answers, with a valid certificate

```bash
curl -sSI https://radar.isoca.space/ | grep -iE '^(HTTP|strict-transport-security)'
```

→ expected: `HTTP/... 200` and `strict-transport-security: max-age=31536000`
if not: `curl: (60)` -> a certificate problem: step 17's log reading. 404 -> `ssh ... ls /srv/sites/radar/current/`.

### 20. PC Git Bash: `isoca.space` and `www.isoca.space` send visitors to github.io

```bash
for h in isoca.space www.isoca.space; do curl -sSI "https://$h/foo" | grep -iE '^(HTTP|location)'; done
```

→ expected: for each name `HTTP/... 302` and `location: https://isabellybaldo.github.io/foo`
if not: `curl: (60)` -> certificate (step 17). 404 from Traefik -> `ssh ... ls /srv/edge/dynamic/` must list `isoca.yml`; run the `edge-config` workflow from the Actions tab of isoca-infra.

## Drills and clean-up

### 21. PC Git Bash: remove the test variable (the smoke check now uses radar.isoca.space)

```bash
gh variable delete DEPLOY_URL -R isabellybaldo/isoca-radar && gh variable list -R isabellybaldo/isoca-radar | grep -c DEPLOY_URL
```

→ expected: `0`
if not: `1` -> the variable is still there; repeat the delete.

### 22. PC Git Bash: deploy again (a second release, so a rollback has somewhere to go)

```bash
R=isabellybaldo/isoca-radar; ID=$(gh run list -R "$R" -w portfolio.yml -b main -L 1 --json databaseId -q '.[0].databaseId'); gh run rerun "$ID" -R "$R" && sleep 45 && gh run watch "$ID" -R "$R" --exit-status >/dev/null; gh run view "$ID" -R "$R" --log | grep -oE 'deployed radar [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: a `deployed radar ...` line with a newer release id than the one in step 9.
if not: the same id as step 9 -> the rerun had not started when the watch ran; wait a minute and run only the last command. A red smoke check -> `radar.isoca.space` is not answering 200: see "If something breaks later".

### 23. PC Git Bash: the rollback drill

```bash
gh workflow run rollback.yml -R isabellybaldo/isoca-infra -f site=radar && sleep 20 && RID=$(gh run list -R isabellybaldo/isoca-infra -w rollback.yml -L 1 --json databaseId -q '.[0].databaseId') && gh run watch "$RID" -R isabellybaldo/isoca-infra --exit-status >/dev/null; gh run view "$RID" -R isabellybaldo/isoca-infra --log | grep -oE 'rolled back radar to [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: one line `rolled back radar to <the step 9 release id>`
if not: `refused: no older release` -> step 22 did not create a second release. `secret ... missing` for isoca-infra -> runbook 1 step 53. Any other refusal text is the box's own reason.

### 24. PC Git Bash: the site is still up after the rollback

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://radar.isoca.space/ && curl -s -o /dev/null -w '%{http_code}\n' https://radar.isoca.space/math
```

→ expected: `200` twice.
if not: run step 25 now; if it is still not 200, see "If something breaks later".

### 25. PC Git Bash: deploy the latest build again (back to the newest release)

```bash
R=isabellybaldo/isoca-radar; ID=$(gh run list -R "$R" -w portfolio.yml -b main -L 1 --json databaseId -q '.[0].databaseId'); gh run rerun "$ID" -R "$R" && sleep 45 && gh run watch "$ID" -R "$R" --exit-status >/dev/null; gh run view "$ID" -R "$R" --log | grep -oE 'deployed radar [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' | tail -n 1
```

→ expected: `deployed radar ...` with a release id newer than the one in step 22.
if not: same id as step 22 -> wait a minute and repeat only the last command.

### 26. PC Git Bash: remove the test route (`radar-test`, `new.isoca.space`) and commit

```bash
cd ~/PycharmProjects/isoca-infra && git switch main && git pull --ff-only && sed -i '1,2c# radar.isoca.space' edge/dynamic/radar.yml && sed -i '/^    radar-test:/,/^$/d' edge/dynamic/radar.yml && sed -i 's/ new\.isoca\.space;/;/' edge/nginx/sites.conf && sed -i '/^req "\$NP" new\.isoca\.space/d; /^sreq new\.isoca\.space/,+1d' tests/edge.test.sh && grep -rc 'new\.isoca\.space' edge tests | grep -v ':0$'; bash tests/edge.test.sh | tail -n 2; [ "${PIPESTATUS[0]}" = 0 ] && bash tests/no-secrets.sh && git commit -qam "edge: drop the new.isoca.space test route, DNS has moved" && git log --oneline -1
```

→ expected: no `new.isoca.space` file listed by grep, `N passed, 0 failed` (Docker runs for a few minutes), `no-secrets: clean (...)`, then the new commit.
if not: a test fails -> `git checkout -- .` and look at the failing line before retrying. The sed lines change `radar.yml` (the router and its comment), `sites.conf` (`server_name`) and the three test lines that expected the test host.

### 27. PC Git Bash: push it; the `edge-config` workflow sends the Traefik change to the box

```bash
cd ~/PycharmProjects/isoca-infra && git push origin main && sleep 25 && ID=$(gh run list -R isabellybaldo/isoca-infra -w edge-config.yml -L 1 --json databaseId -q '.[0].databaseId') && gh run watch "$ID" -R isabellybaldo/isoca-infra --exit-status >/dev/null; gh run view "$ID" -R isabellybaldo/isoca-infra --log | grep -oE 'edge config [0-9]+ files' | tail -n 1
```

→ expected: `edge config 3 files`
if not: no line -> `gh run view "$ID" -R isabellybaldo/isoca-infra --log-failed | tail -30`. Nothing started -> the push touched no `edge/dynamic/**` file; step 26 did not change `radar.yml`.

### 28. PC Git Bash: on the box, take the new nginx config and reload nginx

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"; cd ~/PycharmProjects/isoca-infra && set -a && . ./local.env && set +a && ssh -t -p "$SSH_PORT" "$ADMIN@$VPS_IP" 'sudo git -C /srv/isoca-infra pull --ff-only && sudo docker compose -f /srv/isoca-infra/edge/compose.yml exec nginx nginx -t && sudo docker compose -f /srv/isoca-infra/edge/compose.yml restart nginx && sleep 15 && sudo docker compose -f /srv/isoca-infra/edge/compose.yml ps'
```

→ expected: the pull fast-forwards, `nginx: configuration file ... test is successful`, nginx back to `healthy`, traefik `Up`. (`docker compose up -d` alone would not apply this: compose.yml did not change, only the mounted file.)
if not: `test failed` -> do not restart; `sudo git -C /srv/isoca-infra checkout HEAD~1 -- edge/nginx/sites.conf` puts the old file back. nginx `unhealthy` after restart -> same rollback, then restart nginx again.

### 29. PC Git Bash: the test name is gone, the real ones still work

```bash
curl -skI https://new.isoca.space/ | head -n 1; curl -s -o /dev/null -w 'radar %{http_code}\n' https://radar.isoca.space/; curl -s -o /dev/null -w 'isoca %{http_code}\n' https://isoca.space/
```

→ expected: `HTTP/... 404`, `radar 200`, `isoca 302`
if not: `new.isoca.space` still 200 -> the edge-config run (step 27) or the nginx restart (step 28) did not apply. `radar` not 200 -> roll back the config: `git revert HEAD`, push, rerun step 28.

### 30. Hostinger browser: delete the `new` record and raise the TTLs back to 3600

```text
DNS records: delete the A record "new". Set TTL 3600 on @, www, radar.
```

→ expected: no `new` record; the three records show TTL 3600.
if not: a wrong record deleted -> re-enter it from the step 1 export.

### 31. PC Git Bash: final look

```bash
for u in https://radar.isoca.space/ https://radar.isoca.space/math https://isoca.space/ https://www.isoca.space/; do curl -s -o /dev/null -w "$u %{http_code}\n" "$u"; done
```

→ expected: `200`, `200`, `302`, `302`. The cut-over is done.
if not: the one that differs -> its step above (19 or 20); the rollback workflow undoes a bad deploy.

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
