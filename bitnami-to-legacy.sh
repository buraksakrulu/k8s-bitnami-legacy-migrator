#!/usr/bin/env bash
# migrate.sh — Bitnami → Bitnamilegacy migration tool for Kubernetes workloads
# Features:
# - plan | apply | verify | continue | interactive
# - JSON Patch generation for containers/initContainers image fields
# - Case-insensitive bitnami/ → bitnamilegacy/ conversion
# - Rollout status wait (deploy/ds/sts)
# - State/Log file with context & resource UID to avoid false "verified" skips
# - Live recheck before skipping verified items; optional FORCE_RECHECK=1
# - Interactive TTY-safe prompts

set -euo pipefail

ACTION="${1:-plan}"                        # plan | apply | verify | continue | interactive
STATE_FILE="${STATE_FILE:-bitnami-migration-state.jsonl}"
TIMEOUT="${TIMEOUT:-180s}"
NAMESPACE_SELECTOR="${NAMESPACE_SELECTOR:-}"   # e.g. "ns1,ns2"
KINDS="${KINDS:-deploy,ds,sts,cronjob}"

usage() {
  cat <<EOF
Usage: $0 [plan|apply|verify|continue|interactive]

ENV:
  STATE_FILE=bitnami-migration-state.jsonl
  TIMEOUT=180s
  NAMESPACE_SELECTOR="ns1,ns2"     # if empty, scans all namespaces
  KINDS="deploy,ds,sts,cronjob"
  FORCE_RECHECK=1                  # if set, even verified items are live-checked and reprocessed if needed
EOF
}

need() { command -v "$1" >/dev/null || { echo "Missing dependency: $1" >&2; exit 1; }; }
need kubectl; need jq

# Identify current kubectl context (for state keying)
CONTEXT_ID="$(kubectl config current-context 2>/dev/null || echo unknown)"

# Open /dev/tty for prompts
TTY_FD=
if [[ -r /dev/tty ]]; then
  exec 3</dev/tty
  TTY_FD=3
elif [[ -t 0 ]]; then
  TTY_FD=0
else
  TTY_FD=
fi

prompt_read() {
  local __var="$1"; shift
  local __msg="${*:-> }"
  if [[ -n "${TTY_FD}" ]]; then
    printf "%s" "${__msg}" > /dev/tty 2>/dev/null || printf "%s" "${__msg}" 1>&2
    IFS= read -u "${TTY_FD}" -r "$__var" || true
  else
    echo "ERROR: No TTY available for interactive input." >&2
    exit 2
  fi
}

# Fetch workloads
fetch_workloads() {
  local kinds="${KINDS}"
  if [[ -z "${NAMESPACE_SELECTOR}" ]]; then
    kubectl get ${kinds} -A -o json
  else
    local out_items="[]"
    IFS=',' read -r -a NSLIST <<< "${NAMESPACE_SELECTOR}"
    for ns in "${NSLIST[@]}"; do
      local chunk chunk_items
      chunk="$(kubectl -n "${ns}" get ${kinds} -o json 2>/dev/null || echo '{"items":[]}' )"
      chunk_items="$(jq -c '.items' <<< "${chunk}")"
      out_items="$(jq -c --argjson a "${out_items}" --argjson b "${chunk_items}" -n '$a + $b')"
    done
    jq -n --argjson items "${out_items}" '{items:$items}'
  fi
}

# Generate JSON patch ops
gen_patch_ops_for_item() {
  local item_json="$1"
  jq -c '
    def needs_change(img):
      (img | test("(^|.*/)bitnami/"; "i")) and
      (img | test("(^|.*/)bitnamilegacy/"; "i") | not);

    def to_legacy(img):
      img | sub("bitnami/"; "bitnamilegacy/"; "i");

    . as $it
    | ($it.kind) as $kind
    | (if $kind=="CronJob" then
         ["spec","jobTemplate","spec","template","spec"]
       else
         ["spec","template","spec"]
       end) as $base

    | (try (getpath($base + ["containers"]))     catch null) as $containers
    | (try (getpath($base + ["initContainers"])) catch null) as $inits

    | (
        ( if ($containers|type=="array") then
            [ $containers
              | to_entries[]
              | select((.value|type)=="object" and (.value.image? != null))
              | select(needs_change(.value.image))
              | {op:"replace",
                 path: ("/" + (($base + ["containers", (.key|tostring), "image"]) | join("/"))),
                 value: (to_legacy(.value.image))} ]
          else [] end)
        +
        ( if ($inits|type=="array") then
            [ $inits
              | to_entries[]
              | select((.value|type)=="object" and (.value.image? != null))
              | select(needs_change(.value.image))
              | {op:"replace",
                 path: ("/" + (($base + ["initContainers", (.key|tostring), "image"]) | join("/"))),
                 value: (to_legacy(.value.image))} ]
          else [] end)
      ) as $ops
    | if ($ops | length) > 0 then $ops else empty end
  ' <<< "${item_json}"
}

# Summarize changes
summarize_item_changes() {
  local item_json="$1"
  jq -r '
    def needs_change(img):
      (img | test("(^|.*/)bitnami/"; "i")) and
      (img | test("(^|.*/)bitnamilegacy/"; "i") | not);

    def to_legacy(img):
      img | sub("bitnami/"; "bitnamilegacy/"; "i");

    . as $it
    | ($it.kind) as $kind
    | ($it.metadata.name) as $name
    | ($it.metadata.namespace) as $ns
    | (if $kind=="CronJob" then
         .spec.jobTemplate.spec.template.spec
       else
         .spec.template.spec
       end) as $spec

    | [
        (($spec.containers // [])
         | select(type=="array")
         | to_entries[]
         | select((.value|type)=="object" and (.value.image? != null))
         | select(needs_change(.value.image))
         | [$kind,$name,$ns,"containers",     .value.name, .value.image, to_legacy(.value.image)]),
        (($spec.initContainers // [])
         | select(type=="array")
         | to_entries[]
         | select((.value|type)=="object" and (.value.image? != null))
         | select(needs_change(.value.image))
         | [$kind,$name,$ns,"initContainers", .value.name, .value.image, to_legacy(.value.image)])
      ]
    | .[]
    | @tsv
  ' <<< "${item_json}"
}

apply_patch() {
  local kind="$1" ns="$2" name="$3" patch_json="$4"
  kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${patch_json}" 1>/dev/null
}

verify_rollout() {
  local kind="$1" ns="$2" name="$3"
  case "${kind}" in
    Deployment|DaemonSet|StatefulSet)
      kubectl -n "${ns}" rollout status "${kind,,}/${name}" --timeout="${TIMEOUT}"
      ;;
    CronJob)
      echo "CronJob/${name}: template updated (no rollout)."
      ;;
  esac
}

write_state() {
  local phase="$1" kind="$2" ns="$3" name="$4" extra="${5:-}"
  local uid
  uid="$(kubectl -n "$ns" get "${kind,,}/$name" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  jq -nc \
    --arg t "$(date --iso-8601=seconds 2>/dev/null || date -Iseconds)" \
    --arg phase "$phase" --arg kind "$kind" --arg ns "$ns" --arg name "$name" \
    --arg ctx "$CONTEXT_ID" --arg uid "$uid" --arg extra "$extra" \
    '{ts:$t, phase:$phase, kind:$kind, namespace:$ns, name:$name, context:$ctx, uid:$uid, extra:$extra}' \
    >> "${STATE_FILE}"
}

is_done() {
  local kind="$1" ns="$2" name="$3"
  [[ -f "${STATE_FILE}" ]] || return 1
  local current_uid
  current_uid="$(kubectl -n "$ns" get "${kind,,}/$name" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  jq -r --arg k "$kind" --arg n "$ns" --arg m "$name" \
        --arg ctx "$CONTEXT_ID" --arg uid "$current_uid" '
      select(.kind==$k and .namespace==$n and .name==$m and .context==$ctx and .uid==$uid and .phase=="verified") | 1
    ' "${STATE_FILE}" | grep -q 1
}

# Live recheck
live_needs_change() {
  local kind="$1" ns="$2" name="$3"
  local live; live="$(kubectl -n "$ns" get "${kind,,}/$name" -o json 2>/dev/null || echo "")"
  if [[ -z "$live" ]]; then
    return 1
  fi
  jq -e '
    def needs(img):
      (img | test("(^|.*/)bitnami/"; "i")) and
      (img | test("(^|.*/)bitnamilegacy/"; "i") | not);
    [
      (..|objects|select(has("image"))|.image?|strings | select(needs(.)))
    ] | length > 0
  ' >/dev/null 2>&1 <<< "$live"
}

### ACTIONS ###

plan() {
  local all; all="$(fetch_workloads)"
  echo "# İncelenen öğe sayısı: $(jq '.items|length' <<< "$all")"
  while read -r item; do
    local ops cnt
    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    if [[ "$cnt" -gt 0 ]]; then
      summarize_item_changes "$item" \
        | awk -F'\t' '{printf "%-11s %-35s %-20s %-15s %-20s\n    FROM: %s\n    TO:   %s\n\n", $1,$2,$3,$4,$5,$6,$7}'
    fi
  done < <(jq -c '.items[]' <<< "$all")
  echo "Plan tamam."
}

apply_all() {
  local all; all="$(fetch_workloads)"
  while read -r item; do
    local kind ns name ops cnt
    kind="$(jq -r '.kind' <<< "$item")"
    ns="$(jq -r '.metadata.namespace' <<< "$item")"
    name="$(jq -r '.metadata.name' <<< "$item")"

    if is_done "$kind" "$ns" "$name"; then
      if [[ "${FORCE_RECHECK:-0}" == "1" ]] && live_needs_change "$kind" "$ns" "$name"; then
        echo "⚠️  Verified görünüyor ama canlı objede hâlâ bitnami var: ${kind}/${name} (${ns}) — yeniden işlenecek."
      else
        echo "Atlanıyor (verified): ${kind}/${name} (${ns})"
        continue
      fi
    fi

    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    [[ "$cnt" -eq 0 ]] && continue

    echo "Uygulanıyor: ${kind}/${name} (${ns}) -> ${cnt} değişiklik"
    write_state "applying" "$kind" "$ns" "$name" "$(jq -c <<< "$ops")"
    kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${ops}" --dry-run=server -o yaml >/dev/null
    apply_patch "$kind" "$ns" "$name" "$ops"
    write_state "applied" "$kind" "$ns" "$name" ""
    verify_rollout "$kind" "$ns" "$name"
    write_state "verified" "$kind" "$ns" "$name" ""
  done < <(jq -c '.items[]' <<< "$all")
  echo "Apply tamam."
}

verify_all() {
  local all; all="$(fetch_workloads)"
  while read -r item; do
    local kind ns name ops cnt
    kind="$(jq -r '.kind' <<< "$item")"
    ns="$(jq -r '.metadata.namespace' <<< "$item")"
    name="$(jq -r '.metadata.name' <<< "$item")"

    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    if [[ "$cnt" -gt 0 ]]; then
      echo "UYARI: ${kind}/${name} (${ns}) hâlâ bitnami içeriyor (değişmemiş)."
    else
      echo "OK: ${kind}/${name} (${ns}) legacy ile güncel."
    fi
  done < <(jq -c '.items[]' <<< "$all")
}

continue_run() { apply_all; }

interactive() {
  local all; all="$(fetch_workloads)"
  local apply_all_rest="no"

  while read -r item; do
    local kind ns name ops cnt choice
    kind="$(jq -r '.kind' <<< "$item")"
    ns="$(jq -r '.metadata.namespace' <<< "$item")"
    name="$(jq -r '.metadata.name' <<< "$item")"

    if is_done "$kind" "$ns" "$name"; then
      if [[ "${FORCE_RECHECK:-0}" == "1" ]] && live_needs_change "$kind" "$ns" "$name"; then
        echo "⚠️  Verified görünüyor ama canlı objede hâlâ bitnami var: ${kind}/${name} (${ns}) — yeniden sorulacak."
      else
        echo "Atlanıyor (verified): ${kind}/${name} (${ns})"
        continue
      fi
    fi

    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    [[ "$cnt" -eq 0 ]] && continue

    echo
    echo "Kaynak: ${kind}/${name} (ns: ${ns}) – ${cnt} değişiklik:"
    summarize_item_changes "$item" \
      | awk -F'\t' '{printf "  %-15s %-20s\n    FROM: %s\n    TO:   %s\n", $4,$5,$6,$7}'

    if [[ "$apply_all_rest" == "yes" ]]; then
      choice="y"
    else
      prompt_read choice "[y] uygula  [s] atla  [a] hepsini uygula  [p] patch göster  [q] çık > "
    fi

    case "${choice:-}" in
      y|Y|a|A)
        [[ "${choice:-}" == [aA] ]] && apply_all_rest="yes"
        write_state "applying" "$kind" "$ns" "$name" "$(jq -c <<< "$ops")"
        kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${ops}" --dry-run=server -o yaml >/dev/null
        apply_patch "$kind" "$ns" "$name" "$ops"
        write_state "applied" "$kind" "$ns" "$name" ""
        verify_rollout "$kind" "$ns" "$name"
        write_state "verified" "$kind" "$ns" "$name" ""
        ;;
      p|P)
        echo "PATCH JSON:"; echo "$ops" | jq .
        prompt_read choice "[y] uygula  [s] atla  [a] hepsini uygula  [q] çık > "
        if [[ "${choice:-}" == [yY] || "${choice:-}" == [aA] ]]; then
          [[ "${choice:-}" == [aA] ]] && apply_all_rest="yes"
          write_state "applying" "$kind" "$ns" "$name" "$(jq -c <<< "$ops")"
          kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${ops}" --dry-run=server -o yaml >/dev/null
          apply_patch "$kind" "$ns" "$name" "$ops"
          write_state "applied" "$kind" "$ns" "$name" ""
          verify_rollout "$kind" "$ns" "$name"
          write_state "verified" "$kind" "$ns" "$name" ""
        else
          echo "Atlandı."
        fi
        ;;
      s|S)
        echo "Atlandı."
        ;;
      q|Q)
        echo "Çıkılıyor. Sonra '$0 continue' ile devam edebilirsin."
        exit 0
        ;;
      *)
        echo "Anlaşılmadı, atlandı."
        ;;
    esac
  done < <(jq -c '.items[]' <<< "$all")

  echo; echo "Etkileşimli tur tamam."
}

case "${ACTION}" in
  plan)        plan ;;
  apply)       apply_all ;;
  verify)      verify_all ;;
  continue)    continue_run ;;
  interactive) interactive ;;
  *) usage; exit 1 ;;
esac

bsakrulu@vm-bsakrulu:~/migration-to-legacy-bitnami/test2/test3/test4$ 
bsakrulu@vm-bsakrulu:~/migration-to-legacy-bitnami/test2/test3/test4$ 
bsakrulu@vm-bsakrulu:~/migration-to-legacy-bitnami/test2/test3/test4$ 
bsakrulu@vm-bsakrulu:~/migration-to-legacy-bitnami/test2/test3/test4$ cat ch.sh
#!/usr/bin/env bash
# migrate.sh — Bitnami → Bitnamilegacy migration tool for Kubernetes workloads
# Features:
# - plan | apply | verify | continue | interactive
# - JSON Patch generation for containers/initContainers image fields
# - Case-insensitive bitnami/ → bitnamilegacy/ conversion
# - Rollout status wait (deploy/ds/sts)
# - State/Log file with context & resource UID to avoid false "verified" skips
# - Live recheck before skipping verified items; optional FORCE_RECHECK=1
# - Interactive TTY-safe prompts

set -euo pipefail

ACTION="${1:-plan}"                        # plan | apply | verify | continue | interactive
STATE_FILE="${STATE_FILE:-bitnami-migration-state.jsonl}"
TIMEOUT="${TIMEOUT:-180s}"
NAMESPACE_SELECTOR="${NAMESPACE_SELECTOR:-}"   # e.g. "ns1,ns2"
KINDS="${KINDS:-deploy,ds,sts,cronjob}"

usage() {
  cat <<EOF
Usage: $0 [plan|apply|verify|continue|interactive]

ENV:
  STATE_FILE=bitnami-migration-state.jsonl
  TIMEOUT=180s
  NAMESPACE_SELECTOR="ns1,ns2"     # if empty, scans all namespaces
  KINDS="deploy,ds,sts,cronjob"
  FORCE_RECHECK=1                  # if set, even verified items are live-checked and reprocessed if needed
EOF
}

need() { command -v "$1" >/dev/null || { echo "Missing dependency: $1" >&2; exit 1; }; }
need kubectl; need jq

# Identify current kubectl context (for state keying)
CONTEXT_ID="$(kubectl config current-context 2>/dev/null || echo unknown)"

# Open /dev/tty for prompts
TTY_FD=
if [[ -r /dev/tty ]]; then
  exec 3</dev/tty
  TTY_FD=3
elif [[ -t 0 ]]; then
  TTY_FD=0
else
  TTY_FD=
fi

prompt_read() {
  local __var="$1"; shift
  local __msg="${*:-> }"
  if [[ -n "${TTY_FD}" ]]; then
    printf "%s" "${__msg}" > /dev/tty 2>/dev/null || printf "%s" "${__msg}" 1>&2
    IFS= read -u "${TTY_FD}" -r "$__var" || true
  else
    echo "ERROR: No TTY available for interactive input." >&2
    exit 2
  fi
}

# Fetch workloads
fetch_workloads() {
  local kinds="${KINDS}"
  if [[ -z "${NAMESPACE_SELECTOR}" ]]; then
    kubectl get ${kinds} -A -o json
  else
    local out_items="[]"
    IFS=',' read -r -a NSLIST <<< "${NAMESPACE_SELECTOR}"
    for ns in "${NSLIST[@]}"; do
      local chunk chunk_items
      chunk="$(kubectl -n "${ns}" get ${kinds} -o json 2>/dev/null || echo '{"items":[]}' )"
      chunk_items="$(jq -c '.items' <<< "${chunk}")"
      out_items="$(jq -c --argjson a "${out_items}" --argjson b "${chunk_items}" -n '$a + $b')"
    done
    jq -n --argjson items "${out_items}" '{items:$items}'
  fi
}

# Generate JSON patch ops
gen_patch_ops_for_item() {
  local item_json="$1"
  jq -c '
    def needs_change(img):
      (img | test("(^|.*/)bitnami/"; "i")) and
      (img | test("(^|.*/)bitnamilegacy/"; "i") | not);

    def to_legacy(img):
      img | sub("bitnami/"; "bitnamilegacy/"; "i");

    . as $it
    | ($it.kind) as $kind
    | (if $kind=="CronJob" then
         ["spec","jobTemplate","spec","template","spec"]
       else
         ["spec","template","spec"]
       end) as $base

    | (try (getpath($base + ["containers"]))     catch null) as $containers
    | (try (getpath($base + ["initContainers"])) catch null) as $inits

    | (
        ( if ($containers|type=="array") then
            [ $containers
              | to_entries[]
              | select((.value|type)=="object" and (.value.image? != null))
              | select(needs_change(.value.image))
              | {op:"replace",
                 path: ("/" + (($base + ["containers", (.key|tostring), "image"]) | join("/"))),
                 value: (to_legacy(.value.image))} ]
          else [] end)
        +
        ( if ($inits|type=="array") then
            [ $inits
              | to_entries[]
              | select((.value|type)=="object" and (.value.image? != null))
              | select(needs_change(.value.image))
              | {op:"replace",
                 path: ("/" + (($base + ["initContainers", (.key|tostring), "image"]) | join("/"))),
                 value: (to_legacy(.value.image))} ]
          else [] end)
      ) as $ops
    | if ($ops | length) > 0 then $ops else empty end
  ' <<< "${item_json}"
}

# Summarize changes
summarize_item_changes() {
  local item_json="$1"
  jq -r '
    def needs_change(img):
      (img | test("(^|.*/)bitnami/"; "i")) and
      (img | test("(^|.*/)bitnamilegacy/"; "i") | not);

    def to_legacy(img):
      img | sub("bitnami/"; "bitnamilegacy/"; "i");

    . as $it
    | ($it.kind) as $kind
    | ($it.metadata.name) as $name
    | ($it.metadata.namespace) as $ns
    | (if $kind=="CronJob" then
         .spec.jobTemplate.spec.template.spec
       else
         .spec.template.spec
       end) as $spec

    | [
        (($spec.containers // [])
         | select(type=="array")
         | to_entries[]
         | select((.value|type)=="object" and (.value.image? != null))
         | select(needs_change(.value.image))
         | [$kind,$name,$ns,"containers",     .value.name, .value.image, to_legacy(.value.image)]),
        (($spec.initContainers // [])
         | select(type=="array")
         | to_entries[]
         | select((.value|type)=="object" and (.value.image? != null))
         | select(needs_change(.value.image))
         | [$kind,$name,$ns,"initContainers", .value.name, .value.image, to_legacy(.value.image)])
      ]
    | .[]
    | @tsv
  ' <<< "${item_json}"
}

apply_patch() {
  local kind="$1" ns="$2" name="$3" patch_json="$4"
  kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${patch_json}" 1>/dev/null
}

verify_rollout() {
  local kind="$1" ns="$2" name="$3"
  case "${kind}" in
    Deployment|DaemonSet|StatefulSet)
      kubectl -n "${ns}" rollout status "${kind,,}/${name}" --timeout="${TIMEOUT}"
      ;;
    CronJob)
      echo "CronJob/${name}: template updated (no rollout)."
      ;;
  esac
}

write_state() {
  local phase="$1" kind="$2" ns="$3" name="$4" extra="${5:-}"
  local uid
  uid="$(kubectl -n "$ns" get "${kind,,}/$name" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  jq -nc \
    --arg t "$(date --iso-8601=seconds 2>/dev/null || date -Iseconds)" \
    --arg phase "$phase" --arg kind "$kind" --arg ns "$ns" --arg name "$name" \
    --arg ctx "$CONTEXT_ID" --arg uid "$uid" --arg extra "$extra" \
    '{ts:$t, phase:$phase, kind:$kind, namespace:$ns, name:$name, context:$ctx, uid:$uid, extra:$extra}' \
    >> "${STATE_FILE}"
}

is_done() {
  local kind="$1" ns="$2" name="$3"
  [[ -f "${STATE_FILE}" ]] || return 1
  local current_uid
  current_uid="$(kubectl -n "$ns" get "${kind,,}/$name" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  jq -r --arg k "$kind" --arg n "$ns" --arg m "$name" \
        --arg ctx "$CONTEXT_ID" --arg uid "$current_uid" '
      select(.kind==$k and .namespace==$n and .name==$m and .context==$ctx and .uid==$uid and .phase=="verified") | 1
    ' "${STATE_FILE}" | grep -q 1
}

# Live recheck
live_needs_change() {
  local kind="$1" ns="$2" name="$3"
  local live; live="$(kubectl -n "$ns" get "${kind,,}/$name" -o json 2>/dev/null || echo "")"
  if [[ -z "$live" ]]; then
    return 1
  fi
  jq -e '
    def needs(img):
      (img | test("(^|.*/)bitnami/"; "i")) and
      (img | test("(^|.*/)bitnamilegacy/"; "i") | not);
    [
      (..|objects|select(has("image"))|.image?|strings | select(needs(.)))
    ] | length > 0
  ' >/dev/null 2>&1 <<< "$live"
}

### ACTIONS ###

plan() {
  local all; all="$(fetch_workloads)"
  echo "# İncelenen öğe sayısı: $(jq '.items|length' <<< "$all")"
  while read -r item; do
    local ops cnt
    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    if [[ "$cnt" -gt 0 ]]; then
      summarize_item_changes "$item" \
        | awk -F'\t' '{printf "%-11s %-35s %-20s %-15s %-20s\n    FROM: %s\n    TO:   %s\n\n", $1,$2,$3,$4,$5,$6,$7}'
    fi
  done < <(jq -c '.items[]' <<< "$all")
  echo "Plan tamam."
}

apply_all() {
  local all; all="$(fetch_workloads)"
  while read -r item; do
    local kind ns name ops cnt
    kind="$(jq -r '.kind' <<< "$item")"
    ns="$(jq -r '.metadata.namespace' <<< "$item")"
    name="$(jq -r '.metadata.name' <<< "$item")"

    if is_done "$kind" "$ns" "$name"; then
      if [[ "${FORCE_RECHECK:-0}" == "1" ]] && live_needs_change "$kind" "$ns" "$name"; then
        echo "⚠️  Verified görünüyor ama canlı objede hâlâ bitnami var: ${kind}/${name} (${ns}) — yeniden işlenecek."
      else
        echo "Atlanıyor (verified): ${kind}/${name} (${ns})"
        continue
      fi
    fi

    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    [[ "$cnt" -eq 0 ]] && continue

    echo "Uygulanıyor: ${kind}/${name} (${ns}) -> ${cnt} değişiklik"
    write_state "applying" "$kind" "$ns" "$name" "$(jq -c <<< "$ops")"
    kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${ops}" --dry-run=server -o yaml >/dev/null
    apply_patch "$kind" "$ns" "$name" "$ops"
    write_state "applied" "$kind" "$ns" "$name" ""
    verify_rollout "$kind" "$ns" "$name"
    write_state "verified" "$kind" "$ns" "$name" ""
  done < <(jq -c '.items[]' <<< "$all")
  echo "Apply tamam."
}

verify_all() {
  local all; all="$(fetch_workloads)"
  while read -r item; do
    local kind ns name ops cnt
    kind="$(jq -r '.kind' <<< "$item")"
    ns="$(jq -r '.metadata.namespace' <<< "$item")"
    name="$(jq -r '.metadata.name' <<< "$item")"

    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    if [[ "$cnt" -gt 0 ]]; then
      echo "UYARI: ${kind}/${name} (${ns}) hâlâ bitnami içeriyor (değişmemiş)."
    else
      echo "OK: ${kind}/${name} (${ns}) legacy ile güncel."
    fi
  done < <(jq -c '.items[]' <<< "$all")
}

continue_run() { apply_all; }

interactive() {
  local all; all="$(fetch_workloads)"
  local apply_all_rest="no"

  while read -r item; do
    local kind ns name ops cnt choice
    kind="$(jq -r '.kind' <<< "$item")"
    ns="$(jq -r '.metadata.namespace' <<< "$item")"
    name="$(jq -r '.metadata.name' <<< "$item")"

    if is_done "$kind" "$ns" "$name"; then
      if [[ "${FORCE_RECHECK:-0}" == "1" ]] && live_needs_change "$kind" "$ns" "$name"; then
        echo "⚠️  Verified görünüyor ama canlı objede hâlâ bitnami var: ${kind}/${name} (${ns}) — yeniden sorulacak."
      else
        echo "Atlanıyor (verified): ${kind}/${name} (${ns})"
        continue
      fi
    fi

    ops="$(gen_patch_ops_for_item "$item" || true)"
    cnt="$(jq 'length' <<< "${ops:-[]}" 2>/dev/null || echo 0)"
    [[ "$cnt" -eq 0 ]] && continue

    echo
    echo "Kaynak: ${kind}/${name} (ns: ${ns}) – ${cnt} değişiklik:"
    summarize_item_changes "$item" \
      | awk -F'\t' '{printf "  %-15s %-20s\n    FROM: %s\n    TO:   %s\n", $4,$5,$6,$7}'

    if [[ "$apply_all_rest" == "yes" ]]; then
      choice="y"
    else
      prompt_read choice "[y] uygula  [s] atla  [a] hepsini uygula  [p] patch göster  [q] çık > "
    fi

    case "${choice:-}" in
      y|Y|a|A)
        [[ "${choice:-}" == [aA] ]] && apply_all_rest="yes"
        write_state "applying" "$kind" "$ns" "$name" "$(jq -c <<< "$ops")"
        kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${ops}" --dry-run=server -o yaml >/dev/null
        apply_patch "$kind" "$ns" "$name" "$ops"
        write_state "applied" "$kind" "$ns" "$name" ""
        verify_rollout "$kind" "$ns" "$name"
        write_state "verified" "$kind" "$ns" "$name" ""
        ;;
      p|P)
        echo "PATCH JSON:"; echo "$ops" | jq .
        prompt_read choice "[y] uygula  [s] atla  [a] hepsini uygula  [q] çık > "
        if [[ "${choice:-}" == [yY] || "${choice:-}" == [aA] ]]; then
          [[ "${choice:-}" == [aA] ]] && apply_all_rest="yes"
          write_state "applying" "$kind" "$ns" "$name" "$(jq -c <<< "$ops")"
          kubectl -n "${ns}" patch "${kind,,}/${name}" --type=json -p "${ops}" --dry-run=server -o yaml >/dev/null
          apply_patch "$kind" "$ns" "$name" "$ops"
          write_state "applied" "$kind" "$ns" "$name" ""
          verify_rollout "$kind" "$ns" "$name"
          write_state "verified" "$kind" "$ns" "$name" ""
        else
          echo "Atlandı."
        fi
        ;;
      s|S)
        echo "Atlandı."
        ;;
      q|Q)
        echo "Çıkılıyor. Sonra '$0 continue' ile devam edebilirsin."
        exit 0
        ;;
      *)
        echo "Anlaşılmadı, atlandı."
        ;;
    esac
  done < <(jq -c '.items[]' <<< "$all")

  echo; echo "Etkileşimli tur tamam."
}

case "${ACTION}" in
  plan)        plan ;;
  apply)       apply_all ;;
  verify)      verify_all ;;
  continue)    continue_run ;;
  interactive) interactive ;;
  *) usage; exit 1 ;;
esac