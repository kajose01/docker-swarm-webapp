#!/usr/bin/env bash
# Demonstrates Swarm features against the running stack; writes evidence/swarm-demo.log
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=evidence/swarm-demo.log; : > $OUT
URL=localhost:8080
log() { echo "$*" | tee -a $OUT; }
hosts() { for i in $(seq 1 "$1"); do curl -s --max-time 3 $URL/ | grep -o '"web_host":"[^"]*"'; done | sort | uniq -c; }
count_of() { curl -s --max-time 3 $URL/ | grep -o '"count":[0-9]*' | cut -d: -f2; }
wait_replicas() { for i in $(seq 1 60); do [ "$(docker service ls --filter name=$1 --format '{{.Replicas}}' | head -1)" = "$2/$2" ] && return 0; sleep 2; done; return 1; }

log "== 1. LOAD BALANCING: 30 requests across 3 web replicas"
hosts 30 | tee -a $OUT

log; log "== 2. SCALING: 3 -> 6 replicas"
docker service scale swarm_web=6 >/dev/null; wait_replicas swarm_web 6
log "replicas: $(docker service ls --filter name=swarm_web --format '{{.Replicas}}')"
hosts 60 | tee -a $OUT
docker service scale swarm_web=3 >/dev/null; wait_replicas swarm_web 3
log "scaled back: $(docker service ls --filter name=swarm_web --format '{{.Replicas}}')"

log; log "== 3. ROLLING UPDATE 1.0.0 -> 1.1.0 while requests keep flowing"
PROBE=/tmp/probe.log; : > $PROBE
( while true; do
    code=$(curl -s -o /tmp/p.body -w '%{http_code}' --max-time 2 $URL/)
    v=$(grep -o '"web_version":"[^"]*"' /tmp/p.body | cut -d'"' -f4)
    echo "$code ${v:-none}" >> $PROBE; sleep 0.2
  done ) &
PID=$!
sleep 3
docker service update --image kaj1/swarm-app:1.1.0 swarm_web 2>&1 | tail -3 | tee -a $OUT
sleep 5; kill $PID 2>/dev/null; wait $PID 2>/dev/null
log "requests during the update, by (HTTP code, version):"
sort $PROBE | uniq -c | tee -a $OUT
log "image now: $(docker service inspect swarm_web --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | cut -d@ -f1)"

log; log "== 4. FAILED UPDATE ROLLS BACK AUTOMATICALLY (image tag that does not exist)"
timeout 240 docker service update --image kaj1/swarm-app:no-such-tag swarm_web 2>&1 | tail -4 | tee -a $OUT
log "update state: $(docker service inspect swarm_web --format '{{.UpdateStatus.State}}')"
log "image after:  $(docker service inspect swarm_web --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | cut -d@ -f1)"
wait_replicas swarm_web 3 && log "replicas: 3/3 again"

log; log "== 5. SELF-HEALING: kill one web container"
C=$(docker ps --filter name=swarm_web -q | head -1)
log "killing container $C"; docker kill "$C" >/dev/null
sleep 3; wait_replicas swarm_web 3
docker service ps swarm_web --format '{{.Name}}  {{.CurrentState}}' | head -6 | tee -a $OUT

log; log "== 6. DATABASE FAILURE: kill the db container, data must survive (volume)"
B=$(count_of); log "counter before: $B"
docker kill "$(docker ps --filter name=swarm_db -q)" >/dev/null
A=""; for i in $(seq 1 60); do A=$(count_of); [ -n "$A" ] && break; sleep 2; done
log "counter after db restart: ${A:-none}"
[ -n "$A" ] && [ -n "$B" ] && [ "$A" -gt "$B" ] && log "RESULT: PASS, counter continued from the stored value" || log "RESULT: FAIL"
log; log "DONE"
