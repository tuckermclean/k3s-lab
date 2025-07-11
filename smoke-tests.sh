#!/usr/bin/env bash
set -euo pipefail

echo "1️⃣  K8s cluster health"
kubectl get nodes --no-headers | awk '{print $2}' | grep -qv "^Ready$" && { echo "✖ Some nodes not Ready"; exit 1; }

echo "2️⃣  Core system pods"
# list any pods in kube-system in Failed or Unknown state
bad=$(kubectl get pods -n kube-system --no-headers \
  | awk '$3=="Failed"||$3=="Unknown"{print $1" is "$3}')
if [ -n "$bad" ]; then
  echo "✖ Found bad pods:"
  echo "$bad"
  exit 1
fi

echo "3️⃣  Traefik Ingress controller"
kubectl -n kube-system rollout status deploy/traefik

echo "4️⃣  NFS StorageClass & PVC"
kubectl get sc nfs \
  | awk 'NR>1{print $1}' | grep -q "^nfs$"  
kubectl -n media get pvc media-root-pvc \
  | awk 'NR>1{print $2}' | grep -q "^Bound$"

#echo "5️⃣  Cert-Manager is issuing certs"
#kubectl -n cert-manager get certificates --no-headers \
#  | awk '{print $1,$4}' | grep -q "true" \
#  || { echo "✖ cert-manager pods or CRDs missing"; exit 1; }

echo "6️⃣  Authentik service endpoint"
kubectl -n authentik get endpoints authentik-server \
  | awk 'NR>1{print $2}' | grep -q ":" \
  || { echo "✖ authentik-server has no endpoints"; exit 1; }

echo "7️⃣  Authentik HTTP check"
code=$(curl -ks -o /dev/null -w '%{http_code}' https://id.home.dcxxiv.com/if/flow/initial-setup/) 
[ "$code" = "200" ] || { echo "✖ Authentik UI returned $code"; exit 1; }

echo "8️⃣  Jellyfin deployment"
kubectl -n media rollout status deploy/jellyfin

echo "9️⃣  Jellyfin HTTP check"
code=$(curl -ks -o /dev/null -w '%{http_code}' https://jellyfin.home.dcxxiv.com/) 
[ "$code" = "200" ] || [ "$code" = "301" ] || { echo "✖ Jellyfin UI returned $code"; exit 1; }

echo "🔟  NFS mount inside Jellyfin pod"
POD=$(kubectl -n media get pod -l app.kubernetes.io/instance=jellyfin -o jsonpath='{.items[0].metadata.name}')
kubectl -n media exec "$POD" -- sh -c 'mount | grep ":/Media on /media "' \
  || { echo "✖ /media not mounted in Jellyfin"; exit 1; }

echo "🔢  Jellyfin config PVC bound"
kubectl -n media get pvc jellyfin-config -o jsonpath='{.status.phase}' \
  | grep -q '^Bound$' \
  || { echo "✖ jellyfin-config PVC not Bound"; exit 1; }

echo "🔣  /config mounted in Jellyfin pod"
J_POD=$(kubectl -n media get pod -l app.kubernetes.io/name=jellyfin \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n media exec "$J_POD" -- mount | grep -q ' on /config ' \
  || { echo "✖ /config not mounted"; exit 1; }

echo "🔢  Jellyfin media PVC bound"
kubectl -n media get pvc media-root-pvc -o jsonpath='{.status.phase}' \
  | grep -q '^Bound$' \
  || { echo "✖ media-root-pvc not Bound"; exit 1; }

echo "🔣  /media mounted in Jellyfin pod"
kubectl -n media exec "$J_POD" -- mount | grep -q ' on /media ' \
  || { echo "✖ /media not mounted"; exit 1; }

echo "🔢  Authentik PVCs bound"
bad=$(kubectl -n authentik get pvc --no-headers \
  | awk '$2!="Bound"{print $1" is "$2}')
if [ -n "$bad" ]; then
  echo "✖ Found unbound Authentik PVCs:"
  echo "$bad"
  exit 1
fi

echo "🔣  Postgres data mounted in Authentik"
# find the first pod whose name contains "postgresql"
A_POD=$(kubectl -n authentik get pods --no-headers \
  | awk '/postgresql/{print $1; exit}')
if [ -z "$A_POD" ]; then
  echo "✖ No Authentik Postgres pod found"; exit 1
fi
# check for the Bitnami data directory
kubectl -n authentik exec "$A_POD" -- mount \
  | grep -q '/bitnami/postgresql/data' \
  || { echo "✖ Postgres data not mounted"; exit 1; }

echo "✅  Persistent volumes OK for Jellyfin & Authentik"

echo "✅ All checks passed—your stack is complete!"
