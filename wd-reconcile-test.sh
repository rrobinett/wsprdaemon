#!/bin/bash
### Regression tests for the CHU reconciliation functions in ka9q-utils.sh.
### Usage: ./wd-reconcile-test.sh      Exits 0 if all pass, 1 otherwise.
###
### These functions edit the user's wsprdaemon.conf and the radiod conf automatically, so they get
### tests.  The case that matters most is that removing CHU frequency 7850000 must NOT corrupt
### 17850000 (17.85 MHz) -- an earlier unanchored gsub() silently turned it into "1".
set -u
cd "$(dirname "$0")" || exit 1
declare -i PASS=0 FAIL=0
function wd_logger() { :; }                  ### silence WD logging
function sudo() { "$@"; }                    ### tests only touch temp files we already own
eval "$(awk '/^function wd_reconcile_radiod_band_list\(\)/,/^}/' ka9q-utils.sh)"
eval "$(awk '/^function wd_reconcile_wspr_schedule\(\)/,/^}/'  ka9q-utils.sh)"

function check() {   ### check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS+=1; printf "  PASS  %s\n" "$1"
    else FAIL+=1; printf "  FAIL  %s\n        expected: %s\n        actual:   %s\n" "$1" "$2" "$3"; fi
}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "${TMP}"' EXIT

### ---- radiod conf ----
cat > "${TMP}/radiod.conf" <<'CONF'
[WSPR]
freq = "40m7038600 10m28124600"
[WWV-IQ]
freq = "60k000 2500000 3330000 5000000 7850000 10000000 14670000 15000000 17850000 20000000 25000000"
CONF
wd_reconcile_radiod_band_list "${TMP}/radiod.conf" ; rc=$?
wwv=$(awk '/\[WWV-IQ\]/{f=1;next} f&&/freq/{print;exit}' "${TMP}/radiod.conf")
wspr=$(awk '/\[WSPR\]/{f=1;next} f&&/freq/{print;exit}' "${TMP}/radiod.conf")
check "radiod: file reported as changed"        "1" "${rc}"
check "radiod: CHU frequencies removed"         'freq = "60k000 2500000 5000000 10000000 15000000 17850000 20000000 25000000"' "${wwv}"
check "radiod: 17850000 NOT corrupted"          "yes" "$(grep -q '17850000' <<<"${wwv}" && echo yes || echo no)"
check "radiod: no bands added to [WSPR]"        'freq = "40m7038600 10m28124600"' "${wspr}"
wd_reconcile_radiod_band_list "${TMP}/radiod.conf" ; rc=$?
check "radiod: idempotent (2nd run = no change)" "0" "${rc}"

### ---- wsprdaemon.conf ----
cat > "${TMP}/wd.conf" <<'CONF'
WSPR_SCHEDULE=(
   "00:00 RX888,2200,W2 RX888,CHU_3330,I1 RX888,10,W2 RX888,CHU_7850,I1 RX888,20,W2"
   "12:00 RX888,10,W2:F2 RX888,CHU_14670,I1"
)
CONF
wd_reconcile_wspr_schedule "${TMP}/wd.conf" ; rc=$?
check "WD.conf: file reported as changed"        "1" "${rc}"
check "WD.conf: CHU entries removed"             "0" "$(grep -c 'CHU_' "${TMP}/wd.conf")"
check "WD.conf: no 8m band added"                "0" "$(grep -c ',8,' "${TMP}/wd.conf")"
check "WD.conf: 10m entries preserved"           "2" "$(grep -c ',10,' "${TMP}/wd.conf")"
check "WD.conf: result still parses"             "0" "$(bash -n "${TMP}/wd.conf" 2>/dev/null; echo $?)"
wd_reconcile_wspr_schedule "${TMP}/wd.conf" ; rc=$?
check "WD.conf: idempotent (2nd run = no change)" "0" "${rc}"

### ---- multi-radiod site: every conf must be reconciled independently ----
### A multi-RX888 site has one conf per receiver.  Only the KA9Q_CONF_NAME one used to be
### cleaned, so the others kept their CHU channels indefinitely.
mkdir -p "${TMP}/etc"
for inst in dipole ns-bev ; do
    cat > "${TMP}/etc/radiod@${inst}.conf" <<CONF
[WWV-IQ]
freq = "60k000 2500000 3330000 5000000 7850000 10000000 14670000 25000000"
CONF
done
cat > "${TMP}/etc/radiod@clean.conf" <<'CONF'
[WWV-IQ]
freq = "60k000 2500000 5000000 10000000 25000000"
CONF
declare -i changed=0 unchanged=0
for f in "${TMP}"/etc/radiod@*.conf ; do
    wd_reconcile_radiod_band_list "${f}" ; rc=$?
    (( rc == 1 )) && changed+=1
    (( rc == 0 )) && unchanged+=1
done
check "multi-conf: both CHU-bearing confs changed"   "2" "${changed}"
check "multi-conf: the already-clean conf untouched" "1" "${unchanged}"
check "multi-conf: no CHU left in ANY conf"          "0" "$(grep -l -E '3330000|7850000|14670000' "${TMP}"/etc/radiod@*.conf 2>/dev/null | wc -l | tr -d ' ')"

printf "\n  %d passed, %d failed\n" "${PASS}" "${FAIL}"
(( FAIL == 0 ))
