#!/usr/bin/env bash
# Run Report #RR10, §4 (Reproduction). Every line of the report's §4 block appears below, in order and exactly as printed.
# Each step then runs the commands its lines print, one step per invocation:  ./reproduce.sh 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7
# Per the report (§3), openssl -checkend 0 exits 1 once the certificate is past notAfter, so the script does not stop
# on a non-zero exit.
set -uo pipefail
cd "$(dirname "$0")"

step_0() {
# 0. Bring up a kind cluster (node k8s v1.33.4) on the test VM and install cert-manager v1.21.2 from
#    the official Helm chart, with the CRDs and controller log level 4 (chart hash + image digests
#    recorded; rollout confirmed before measuring):
#      kind create cluster --name rr10 --image kindest/node:v1.33.4@sha256:25a6018e48dfcaee478f4a59af81157a437f15e6e140bf103f85a2e7cd0cbbf2
#      helm install cert-manager https://charts.jetstack.io/charts/cert-manager-v1.21.2.tgz \
#        -n cert-manager --create-namespace --set crds.enabled=true --set global.logLevel=4 --wait
#      for d in cert-manager cert-manager-webhook cert-manager-cainjector; do kubectl -n cert-manager rollout status "deploy/$d" --timeout=300s; done
kind create cluster --name rr10 --image kindest/node:v1.33.4@sha256:25a6018e48dfcaee478f4a59af81157a437f15e6e140bf103f85a2e7cd0cbbf2
helm install cert-manager https://charts.jetstack.io/charts/cert-manager-v1.21.2.tgz \
  -n cert-manager --create-namespace --set crds.enabled=true --set global.logLevel=4 --wait
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do kubectl -n cert-manager rollout status "deploy/$d" --timeout=300s; done
}

step_1() {
# 1. Create a SelfSigned Issuer, then a Certificate that expires quickly (Issuer 'selfsigned':
#    spec.selfSigned: {}; Certificate 'cert-a': duration 1h, renewBefore 55m, RSA size 2048,
#    issuerRef -> selfsigned, secretName cert-a-tls).
#      kubectl apply -f step1-manifest.yaml   # the objects below, saved to this file
#      for i in $(seq 1 180); do [ "$(kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 1; done
kubectl apply -f step1-manifest.yaml   # the objects below, saved to this file
for i in $(seq 1 180); do [ "$(kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 1; done
}

step_2() {
# 2. T1 baseline: record Ready status/reason/message (expect the L424 string), status.notAfter
#    (= issuance + 1h), status.renewalTime (= notAfter - 55m), the Secret tls.crt NotAfter (openssl),
#    and that one CertificateRequest completed. If Ready != True here, STOP and report (a design
#    fault, not a branch).
#      kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
#      kubectl get certificate -n rr10 -o wide
#      kubectl get certificaterequest -n rr10 -o wide
#      kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.notAfter}'
#      kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.renewalTime}'
#      kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate -startdate -serial | tr '\n' ' '
kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
kubectl get certificate -n rr10 -o wide
kubectl get certificaterequest -n rr10 -o wide
kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.notAfter}'
kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.renewalTime}'
kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate -startdate -serial | tr '\n' ' '
}

step_3() {
# 3. BLOCK renewal (M1): within the margin before the renewal fires (renewalTime is issuance + ~5m),
#    delete the Issuer 'selfsigned'. Record the deletion time (UTC) and that it precedes renewalTime;
#    immediately re-confirm status.notAfter and the Secret NotAfter are unchanged from T1 (if they
#    diverge, discard the run and re-run -- do not judge a branch). From here to the end of the window,
#    do NOT write to the Certificate, its Secret, its CertificateRequest, or the Issuer (read only).
#      kubectl delete issuer selfsigned -n rr10
kubectl delete issuer selfsigned -n rr10
}

step_4() {
# 4. T2 (~ +5m): record the Issuing condition, whether a new CertificateRequest is created and its
#    condition (Issuer absent -> cannot progress; message verbatim), and Ready (still True is correct).
#      RT=$(date -u -d "$(kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.renewalTime}')" +%s); until [ "$(date -u +%s)" -ge "$RT" ]; do sleep 30; done
#      kubectl get certificate -n rr10 -o wide
#      kubectl get certificaterequest -n rr10 -o wide
RT=$(date -u -d "$(kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.renewalTime}')" +%s); until [ "$(date -u +%s)" -ge "$RT" ]; do sleep 30; done
kubectl get certificate -n rr10 -o wide
kubectl get certificaterequest -n rr10 -o wide
}

step_5() {
# 5. T3 (from +60m, for >= 30 minutes; >= 60 polls): each poll, record Ready status/reason/message/
#    lastTransitionTime, status.notAfter, the Issuing condition, CertificateRequest state, the Secret's
#    openssl -checkend 0 result, the metadata.resourceVersion (+ generation) of the Certificate/Secret/
#    CertificateRequest, kubectl get events -n rr10 (expect no new events), and whether the controller
#    log shows any reconcile of cert-a. Pin the window start/end times and poll count in raw. The helper rv prints the
#    three resourceVersions and the generation on one line; after the window, the count of controller log lines since
#    the window start that name cert-a, its Secret or its requests, and the Events with their times.
#      rv() { echo "rv: certificate $(kubectl get certificate cert-a -n rr10 -o jsonpath='{.metadata.resourceVersion} generation {.metadata.generation}') · secret $(kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.metadata.resourceVersion}') · requests $(kubectl get certificaterequest -n rr10 -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.resourceVersion} {end}')"; }
#      NA=$(date -u -d "$(kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.notAfter}')" +%s); until [ "$(date -u +%s)" -ge "$NA" ]; do sleep 30; done; W=$(date -u +%s); date -u +%T
#      kubectl get certificate -n rr10 -o wide
#      rv
#      kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0   # exits 1 once past NotAfter
#      n=1; until [ "$n" -ge 62 ] && [ $(( $(date -u +%s) - W )) -ge 1830 ]; do d=$(( W + 30 * n - $(date -u +%s) )); [ "$d" -gt 0 ] && sleep "$d"; n=$((n + 1)); date -u +%T; kubectl get certificate -n rr10 -o wide; rv; kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0; done
#      kubectl -n cert-manager logs deploy/cert-manager --timestamps --since-time="$(date -u -d "@$W" +%FT%TZ)" | grep -cE 'rr10/cert-a\b|"cert-a"|cert-a-tls|cert-a-[0-9]+\b|cert-a-[a-z0-9]{5}\b'
#      kubectl get events -n rr10 --sort-by=.lastTimestamp -o custom-columns=LAST:.lastTimestamp,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message
rv() { echo "rv: certificate $(kubectl get certificate cert-a -n rr10 -o jsonpath='{.metadata.resourceVersion} generation {.metadata.generation}') · secret $(kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.metadata.resourceVersion}') · requests $(kubectl get certificaterequest -n rr10 -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.resourceVersion} {end}')"; }
NA=$(date -u -d "$(kubectl get certificate cert-a -n rr10 -o jsonpath='{.status.notAfter}')" +%s); until [ "$(date -u +%s)" -ge "$NA" ]; do sleep 30; done; W=$(date -u +%s); date -u +%T
kubectl get certificate -n rr10 -o wide
rv
kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0   # exits 1 once past NotAfter
n=1; until [ "$n" -ge 62 ] && [ $(( $(date -u +%s) - W )) -ge 1830 ]; do d=$(( W + 30 * n - $(date -u +%s) )); [ "$d" -gt 0 ] && sleep "$d"; n=$((n + 1)); date -u +%T; kubectl get certificate -n rr10 -o wide; rv; kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0; done
kubectl -n cert-manager logs deploy/cert-manager --timestamps --since-time="$(date -u -d "@$W" +%FT%TZ)" | grep -cE 'rr10/cert-a\b|"cert-a"|cert-a-tls|cert-a-[0-9]+\b|cert-a-[a-z0-9]{5}\b'
kubectl get events -n rr10 --sort-by=.lastTimestamp -o custom-columns=LAST:.lastTimestamp,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message
}

step_6() {
# 6. T4 restart recovery: kubectl -n cert-manager rollout restart deploy/cert-manager, wait for
#    rollout status and for the controller to come up (a poll right after restart may hit the old pod),
#    then resume polling and record when Ready/message/Issuing change. The new controller pod is the
#    one that is neither the pod from before the restart nor terminating (at most 60 one-second reads).
#      POD1=$(kubectl -n cert-manager get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
#      kubectl -n cert-manager rollout restart deploy/cert-manager
#      kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
#      for i in $(seq 1 60); do POD2=$(kubectl -n cert-manager get pods -l app.kubernetes.io/component=controller -o json | jq -r --arg old "$POD1" '.items[] | select(.metadata.name != $old and .metadata.deletionTimestamp == null) | .metadata.name' | head -1); [ -n "$POD2" ] && break; sleep 1; done
#      S=$(date -u +%s); for i in $(seq 1 36); do date -u +%T; kubectl get certificate -n rr10 -o wide; kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0; d=$(( S + 5 * i - $(date -u +%s) )); [ "$d" -gt 0 ] && sleep "$d"; done &
#      kubectl -n cert-manager logs -f "$POD2" --timestamps | grep -m1 '"Successfully acquired lease"'
#      wait; S=$(date -u +%s); for i in $(seq 1 6); do date -u +%T; kubectl get certificate -n rr10 -o wide; kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0; d=$(( S + 30 * i - $(date -u +%s) )); [ "$d" -gt 0 ] && sleep "$d"; done
POD1=$(kubectl -n cert-manager get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
kubectl -n cert-manager rollout restart deploy/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
for i in $(seq 1 60); do POD2=$(kubectl -n cert-manager get pods -l app.kubernetes.io/component=controller -o json | jq -r --arg old "$POD1" '.items[] | select(.metadata.name != $old and .metadata.deletionTimestamp == null) | .metadata.name' | head -1); [ -n "$POD2" ] && break; sleep 1; done
S=$(date -u +%s); for i in $(seq 1 36); do date -u +%T; kubectl get certificate -n rr10 -o wide; kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0; d=$(( S + 5 * i - $(date -u +%s) )); [ "$d" -gt 0 ] && sleep "$d"; done &
kubectl -n cert-manager logs -f "$POD2" --timestamps | grep -m1 '"Successfully acquired lease"'
wait; S=$(date -u +%s); for i in $(seq 1 6); do date -u +%T; kubectl get certificate -n rr10 -o wide; kubectl get secret cert-a-tls -n rr10 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -checkend 0; d=$(( S + 30 * i - $(date -u +%s) )); [ "$d" -gt 0 ] && sleep "$d"; done
}

step_7() {
# 7. Tear down (the test cluster only).
#      kind delete cluster --name rr10
kind delete cluster --name rr10
}

case "${1:-}" in
  0) step_0 "${@:2}" ;;
  1) step_1 "${@:2}" ;;
  2) step_2 "${@:2}" ;;
  3) step_3 "${@:2}" ;;
  4) step_4 "${@:2}" ;;
  5) step_5 "${@:2}" ;;
  6) step_6 "${@:2}" ;;
  7) step_7 "${@:2}" ;;
  *) echo "usage: $0 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7  (one step per run, in order; see README)"; exit 2 ;;
esac
