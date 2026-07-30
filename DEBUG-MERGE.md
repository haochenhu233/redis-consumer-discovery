# Debugging `merge` — "no live connections / all source=forward"

Symptom: `merged_report.csv` shows every row as `source=forward` and `live_connection=no`, even
though the backward scan clearly found consumers (`backward/redis_consumers.txt` has rows).

`merge` is **pure file processing** — no genesis / BOSH / `cf` / Vault. So it runs anywhere that
has the output directory (e.g. the VDI in **git-bash**, which is bash 4+). Everything below only
reads files, except Step 4 which re-runs merge.

> Replace `<out>` with your output directory (the base that contains `backward/` and `forward/`).
> Run each block and paste the output.

---

## How merge decides "live"

`merge` reads **`backward/06_classified.tsv`** (not `redis_consumers.txt`) and marks an
`(app_guid, service_instance_guid)` pair **live** when a row has:
- col 1 (`env`) is not the header,
- col 13 (`app_guid`) is non-empty and not `?`,
- col 12 (`redis_deployment`) is **≥ 36 chars** (so the last 36 = the service-instance GUID).

It joins that against the forward `cf-bind` pairs. `source=forward` for **every** row means merge
added **zero** live keys — i.e. every row in `06_classified.tsv` was skipped by the rule above.

---

## Step 0 — environment sanity

```bash
bash --version | head -1                 # need major version 4 or 5 (git-bash is fine)
cd <out>
ls -la backward/06_classified.tsv forward/fwd_binds.tsv    # both must exist and be non-empty
```

## Step 1 — line endings (Windows/VDI copies often get CRLF)

```bash
file backward/06_classified.tsv          # "with CRLF line terminators" = needs fixing
# fix in place if CRLF (harmless if already LF):
sed -i 's/\r$//' backward/06_classified.tsv forward/*.tsv redis-consumer-discovery.sh
```

## Step 2 — confirm column positions

```bash
head -1 backward/06_classified.tsv | tr '\t' '\n' | cat -n
```
Expected: **14** columns, col 5 = `platform`, col 12 = `redis_deployment`, col 13 = `app_guid`,
col 14 = `redis_ip`.
- If you see **13 columns** (no `platform`), this file was made by an **older build** than your
  merge script → `app_guid` is really col 12. Re-run the backward scan with the current script.

## Step 3 — why is each row kept or skipped?

```bash
awk -F'\t' 'NR>1{t++; if($13==""||$13=="?")bg++; else if(length($12)<36)bd++; else ok++}
  END{print "total="t"  ok(kept)="ok"  bad_app_guid="bg"  short_redis_deployment="bd}' backward/06_classified.tsv

# and a couple of real rows:
awk -F'\t' 'NR>=2 && NR<=4{print "--- row "NR" ---";
  print "col12 redis_deployment = [" $12 "]  len=" length($12);
  print "col13 app_guid         = [" $13 "]  len=" length($13)}' backward/06_classified.tsv
```

Read it as:
- **`ok` ≈ total** → rows are valid; merge *should* keep them → go to Step 4/5 (merge bug or
  wrong file).
- **`bad_app_guid` high** → col 13 is `?`/empty in this scan (app_guid didn't resolve) → merge
  can't key on it.
- **`short_redis_deployment` high** → col 12 is `?` or short → the backward classify wrote `?`
  for the deployment → `last-36` yields nothing. Problem is in the backward scan, not merge.

## Step 4 — re-run merge and look at the source split

```bash
# (close merged_report.csv in Excel first, or Windows locks it: "Device or resource busy")
bash redis-consumer-discovery.sh merge np --path <out>
awk -F, 'NR>1{print $16}' <out>/merged_report.csv | sort | uniq -c    # source: forward/backward/both
awk -F, 'NR>1{print $15}' <out>/merged_report.csv | sort | uniq -c    # live_connection: yes/no
```

## Step 5 — do the keys actually overlap? (only if Step 3 said `ok ≈ total`)

Check whether the same `(app_guid, service_instance_guid)` appears on both sides. `service
_instance_guid` = last 36 chars of `redis_deployment`.

```bash
# backward keys: app_guid + SI  (from 06_classified)
awk -F'\t' 'NR>1 && $13!="" && $13!="?" && length($12)>=36 {print $13" "substr($12,length($12)-35)}' \
  backward/06_classified.tsv | sort -u > /tmp/bwd_keys.txt

# forward keys: app_guid + SI  (from fwd_binds: col1=app_guid, col2=service_instance_guid)
awk -F'\t' 'NR>1{print $1" "$2}' forward/fwd_binds.tsv | sort -u > /tmp/fwd_keys.txt

echo "backward keys: $(wc -l < /tmp/bwd_keys.txt)   forward keys: $(wc -l < /tmp/fwd_keys.txt)"
echo "keys in BOTH:  $(comm -12 /tmp/bwd_keys.txt /tmp/fwd_keys.txt | wc -l)"
echo "--- 3 sample backward keys ---"; head -3 /tmp/bwd_keys.txt
echo "--- 3 sample forward keys  ---"; head -3 /tmp/fwd_keys.txt
```

- If **backward keys > 0** but merge still shows no `backward`/`both` rows in Step 4 → genuine
  merge bug (send me the numbers).
- If the sample keys look different in **format** (e.g. backward SI has extra chars, or the
  app_guid differs) → the join key derivation differs between scans.

## Step 6 — minimal join repro (the decisive test)

Step 3 uses `awk`; merge uses a bash `read` loop. If Step 3 says most rows are `ok` but merge
still shows no live connections, run the **exact** loop merge uses and see what it produces:

```bash
cd <out>
declare -A P_BIND P_LIVE ALLKEYS
while IFS=$'\t' read -r app si rest; do
  [ "$app" = app_guid ] && continue
  [ -n "$app" ] && [ -n "$si" ] && { P_BIND["$app $si"]=1; ALLKEYS["$app $si"]=1; }
done < forward/fwd_binds.tsv
while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14; do
  [ "$c1" = env ] && continue
  app="$c13"; dep="$c12"
  { [ -z "$app" ] || [ "$app" = "?" ]; } && continue
  si=""; [ "${#dep}" -ge 36 ] && si="${dep: -36}"
  [ -z "$si" ] && continue
  P_LIVE["$app $si"]=1; ALLKEYS["$app $si"]=1
done < backward/06_classified.tsv
echo "P_BIND=${#P_BIND[@]}  P_LIVE=${#P_LIVE[@]}  ALLKEYS=${#ALLKEYS[@]}"
fwd=0; bwd=0; both=0
for k in "${!ALLKEYS[@]}"; do
  L=no; [ -n "${P_LIVE[$k]:-}" ] && L=yes
  B=no; [ -n "${P_BIND[$k]:-}" ] && B=yes
  if [ "$B" = yes ] && [ "$L" = yes ]; then both=$((both+1)); elif [ "$B" = yes ]; then fwd=$((fwd+1)); else bwd=$((bwd+1)); fi
done
echo "source -> forward=$fwd  backward=$bwd  both=$both"
```

- **`P_LIVE` ≈ (Step-3 ok count)` and `backward`+`both` > 0** → the merge logic is correct; your
  `merged_report.csv` was produced against a **different/empty** `06_classified.tsv`. Re-run
  `merge np --path <out>` pointed at THIS directory.
- **`P_LIVE=0`** → the bash loop skips what `awk` kept → a `\r`/whitespace bug in the loop. Send
  the numbers; the fix is stripping `\r` from the fields.

---

## What to send back

Paste the outputs of **Step 2, Step 3, and Step 6**. Those pin it down: column count + the
keep/skip categorization + whether the exact bash join produces live keys.
