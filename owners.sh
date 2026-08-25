#!/usr/bin/env bash
# owners.sh -- annotate merged_report.csv with the owners to contact per app row.
#     bash owners.sh <merge-base-dir | merged_report.csv>
# Runs in git-bash in the VDI with the existing (admin) cf login. CF-API only.
#
# Owner columns appended per row (by the app's org+space):
#   org_managers  : human org managers (always listed)
#   space_owners  : the space contact -- space manager(s) if any exist, otherwise up to 5
#                   space developers (all of them if fewer than 5)
#   owner_source  : space-manager | space-developers | none
# "Human" = username looks like an email (user@domain.tld). UAA client ids / random-string
# usernames (CI, service accounts) are filtered out.
#
# Output: merged_report_owners.csv next to the input (original left untouched) + aggregate
# coverage stats on stdout. No new data leaves the VDI.
set -uo pipefail

arg="${1:-.}"
if [ -f "$arg" ]; then f="$arg"; base="$(dirname "$arg")"
else base="$arg"; f="$base/merged_report.csv"; fi
[ -s "$f" ] || { echo "ERROR: no merged_report.csv at '$arg'"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq required"; exit 1; }

wdir="$base/.owners"

# --- fetch phase (skipped if RCD_OWNERS_OFFLINE=1: reuse existing .owners intermediates) ---
if [ -z "${RCD_OWNERS_OFFLINE:-}" ]; then
  rm -rf "$wdir"; mkdir -p "$wdir"
  timeout 30 cf curl "/v3/apps?per_page=1" >/dev/null 2>&1 || { echo "ERROR: cf not logged in"; exit 1; }

  # paginate a v3 endpoint keeping BOTH resources and included.users (jsonl files).
  # Fails LOUDLY if the API returns an error document (bad query param, auth, ...) --
  # otherwise a rejected query looks like an inexplicably empty output file.
  paginate(){ # $1=path $2=resources-out $3=users-out
    local next="$1"
    while [ -n "$next" ] && [ "$next" != "null" ]; do
      local page; page=$(timeout 60 cf curl "$next" 2>/dev/null)
      [ -z "$page" ] && break
      if printf '%s' "$page" | jq -e '.errors? // empty' >/dev/null 2>&1; then
        echo "ERROR: CF API rejected: $next" >&2
        printf '%s' "$page" | jq -r '.errors[] | "  \(.title): \(.detail)"' >&2
        exit 1
      fi
      printf '%s' "$page" | jq -c '.resources[]?'      >> "$2"
      printf '%s' "$page" | jq -c '.included.users[]?' >> "$3" 2>/dev/null || true
      next=$(printf '%s' "$page" | jq -r '.pagination.next.href // "null"')
      [ "$next" != "null" ] && [ -n "$next" ] && next="/v3/${next#*/v3/}"
    done
  }

  echo "owners: fetching orgs, spaces, roles (this is a few dozen API calls) ..."
  : > "$wdir/orgs.jsonl"; : > "$wdir/spaces.jsonl"; : > "$wdir/roles.jsonl"; : > "$wdir/users.jsonl"
  paginate "/v3/organizations?per_page=200" "$wdir/orgs.jsonl"   /dev/null
  paginate "/v3/spaces?per_page=200"        "$wdir/spaces.jsonl" /dev/null
  paginate "/v3/roles?types=organization_manager,space_manager,space_developer&per_page=200&include=user" \
           "$wdir/roles.jsonl" "$wdir/users.jsonl"
fi
for x in orgs spaces roles users; do
  [ -s "$wdir/$x.jsonl" ] || { echo "ERROR: no data in $wdir/$x.jsonl"; exit 1; }
done

# --- shaping phase (pure jq): build owners.tsv  org \t space \t org_mgrs \t space_owners \t source ---
jq -rs --slurpfile orgs "$wdir/orgs.jsonl" --slurpfile spaces "$wdir/spaces.jsonl" \
      --slurpfile users "$wdir/users.jsonl" '
  # humans only: username shaped like an email
  def human: (.username // "") | test("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$");
  ($users | map(select(human)) | map({key: .guid, value: .username}) | from_entries) as $u
  | ($orgs   | map({key: .guid, value: .name}) | from_entries) as $on
  | ($spaces | map({key: .guid, value: {name: .name, org: .relationships.organization.data.guid}}) | from_entries) as $sp
  # roles: resolve to username (drops non-humans), bucket by scope+type
  | map(select(.type != null))
  | map({type,
         org:   (.relationships.organization.data.guid // null),
         space: (.relationships.space.data.guid // null),
         user:  ($u[.relationships.user.data.guid] // null)})
  | map(select(.user != null)) as $roles
  | ($roles | map(select(.type=="organization_manager" and .org != null))
            | group_by(.org) | map({key: .[0].org, value: (map(.user)|unique)}) | from_entries) as $omgr
  | ($roles | map(select(.type=="space_manager" and .space != null))
            | group_by(.space) | map({key: .[0].space, value: (map(.user)|unique)}) | from_entries) as $smgr
  | ($roles | map(select(.type=="space_developer" and .space != null))
            | group_by(.space) | map({key: .[0].space, value: (map(.user)|unique)}) | from_entries) as $sdev
  # one row per space: org-name, space-name, org managers, space contact, source
  | $sp | to_entries | map(
      .key as $sg | .value as $s
      | ($smgr[$sg] // []) as $m
      | ($sdev[$sg] // []) as $d
      | { org:   ($on[$s.org] // "?"),
          space: $s.name,
          omgrs: (($omgr[$s.org] // []) | join(";")),
          owners: (if ($m|length) > 0 then ($m|join(";"))
                   elif ($d|length) > 0 then ($d | sort | .[0:5] | join(";"))
                   else "" end),
          src:   (if ($m|length) > 0 then "space-manager"
                  elif ($d|length) > 0 then "space-developers"
                  else "none" end) }
    )
  | .[] | [.org, .space, .omgrs, .owners, .src] | @tsv
' "$wdir/roles.jsonl" > "$wdir/owners.tsv"

nsp=$(wc -l < "$wdir/owners.tsv" | tr -d ' ')
echo "owners: resolved $nsp space(s) -> $wdir/owners.tsv"

# --- join phase (pure awk): append columns to the merged report ---
out="$base/merged_report_owners.csv"
awk '
  NR==FNR { split($0, t, "\t"); key=t[1] SUBSEP t[2]; OM[key]=t[3]; OW[key]=t[4]; SRC[key]=t[5]; next }
  FNR==1 { print $0",org_managers,space_owners,owner_source"; next }
  { split($0, c, ",")              # merged_report: col2=space col3=org (app side)
    key=c[3] SUBSEP c[2]
    om=(key in OM)?OM[key]:""; ow=(key in OW)?OW[key]:""; sc=(key in SRC)?SRC[key]:""
    if (c[2]=="" && c[3]=="") sc=""                      # EXTERNAL rows: leave blank
    print $0 "," om "," ow "," sc }
' "$wdir/owners.tsv" "$f" > "$out"

echo "owners: wrote $out"
echo
echo "== coverage (spaces appearing in the report) =="
awk -F',' 'NR>1 && $2!="" { key=$3 SUBSEP $2; if (!(key in seen)) { seen[key]=1; src[$NF]++ } }
  END { for (s in src) printf "  %-18s %d space(s)\n", (s==""?"(unmatched)":s), src[s] }' "$out"
echo "  (space-manager = addressed to managers; space-developers = fallback, max 5 humans;"
echo "   none = no human owner found -> use org_managers column)"
