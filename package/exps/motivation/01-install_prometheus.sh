#!/usr/bin/env bash
set -euo pipefail

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts \
  --force-update

helm repo update

kubectl config use-context cluster0

helm upgrade --install prom \
  prometheus-community/kube-prometheus-stack \
  --version 87.6.0 \
  --namespace monitoring \
  --create-namespace \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --set prometheus.service.type=NodePort \
  --set prometheus.prometheusSpec.scrapeInterval=15s \
  --set prometheus.prometheusSpec.evaluationInterval=15s \
  --set prometheus.prometheusSpec.enableAdminAPI=true \
  --set prometheus.prometheusSpec.resources.requests.cpu=1000m \
  --set prometheus.prometheusSpec.resources.requests.memory=1024Mi

# ------------------------------------------------------------
# Member clusters
#
# cluster1 =   5s
# cluster2 =  15s
# cluster3 =  30s
# cluster4 =  60s
# cluster5 = 120s
# ------------------------------------------------------------

while read -r cluster interval; do
  echo
  echo "Installing Prometheus on cluster${cluster}: ${interval}"

  kubectl config use-context cluster${cluster}
  helm upgrade --install prom \
    prometheus-community/kube-prometheus-stack \
    --version 87.6.0 \
    --namespace monitoring \
    --create-namespace \
    --set grafana.enabled=false \
    --set alertmanager.enabled=false \
    --set prometheus.service.type=NodePort \
    --set prometheus.prometheusSpec.scrapeInterval="${interval}" \
    --set prometheus.prometheusSpec.evaluationInterval=15s \
    --set prometheus.prometheusSpec.enableAdminAPI=true \
    --set prometheus.prometheusSpec.resources.requests.cpu=1000m \
    --set prometheus.prometheusSpec.resources.requests.memory=1024Mi

done <<EOF
1 5s
2 15s
3 30s
4 60s
5 120s
EOF