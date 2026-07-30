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

---

## What to send back

Paste the outputs of **Step 2, Step 3, and Step 4**. Those three pin it down:
`06_classified.tsv` column count + the keep/skip categorization + the merged source split.
