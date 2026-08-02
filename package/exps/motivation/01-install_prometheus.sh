#!/usr/bin/env bash
set -euo pipefail

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update

helm repo update


# Install local Prometheus on member clusters

while read -r cluster interval; do
  echo
  echo "============================================================"
  echo "Installing Prometheus on cluster${cluster}"
  echo "Scrape interval: ${interval}"
  echo "============================================================"

  helm upgrade --install prometheus \
    prometheus-community/kube-prometheus-stack \
    --version 87.6.0 \
    --namespace monitoring \
    --create-namespace \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    --set grafana.enabled=false \
    --set alertmanager.enabled=false \
    --set prometheus.service.type=NodePort \
    --set prometheus.prometheusSpec.scrapeInterval="${interval}" \
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

# ============================================================
# 2. Start management values file
# ============================================================

cat > management-values.yaml <<'EOF'
grafana:
  enabled: false

alertmanager:
  enabled: false

prometheus:
  service:
    type: NodePort

  prometheusSpec:
    scrapeInterval: 15s
    enableAdminAPI: true

    resources:
      requests:
        cpu: 1000m
        memory: 1024Mi

    additionalScrapeConfigs:
EOF

# ============================================================
# 3. Detect member IP and Prometheus NodePort automatically
#
# The kubeconfig is used to:
#   1. confirm the API server
#   2. query the member control-plane InternalIP
#   3. query the Prometheus NodePort
# ============================================================

for cluster in 1 2 3 4 5; do
  echo
  echo "============================================================"
  echo "Detecting federation target for cluster${cluster}"
  echo "============================================================"

  kubeconfig="$HOME/.kube/cluster${cluster}"

  api_server="$(
    kubectl \
      --kubeconfig "${kubeconfig}" \
      config view \
      --minify \
      -o jsonpath='{.clusters[0].cluster.server}'
  )"

  member_ip="$(
    kubectl \
      --kubeconfig "${kubeconfig}" \
      get nodes \
      -l node-role.kubernetes.io/control-plane \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
  )"

  # Some clusters use the older master label.
  if [[ -z "${member_ip}" ]]; then
    member_ip="$(
      kubectl \
        --kubeconfig "${kubeconfig}" \
        get nodes \
        -l node-role.kubernetes.io/master \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
    )"
  fi

  # Final fallback: use the first Kubernetes node.
  if [[ -z "${member_ip}" ]]; then
    member_ip="$(
      kubectl \
        --kubeconfig "${kubeconfig}" \
        get nodes \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
    )"
  fi

  if [[ -z "${member_ip}" ]]; then
    echo "ERROR: cannot determine a node InternalIP for cluster${cluster}"
    exit 1
  fi

  service_name="$(
    kubectl \
      --kubeconfig "${kubeconfig}" \
      --namespace monitoring \
      get service \
      -l app.kubernetes.io/name=prometheus \
      -o jsonpath='{.items[0].metadata.name}'
  )"

  if [[ -z "${service_name}" ]]; then
    echo "ERROR: cannot find Prometheus Service on cluster${cluster}"
    exit 1
  fi

  node_port="$(
    kubectl \
      --kubeconfig "${kubeconfig}" \
      --namespace monitoring \
      get service "${service_name}" \
      -o jsonpath='{.spec.ports[?(@.name=="http-web")].nodePort}'
  )"

  # Fallback if the Prometheus Service port has another name.
  if [[ -z "${node_port}" ]]; then
    node_port="$(
      kubectl \
        --kubeconfig "${kubeconfig}" \
        --namespace monitoring \
        get service "${service_name}" \
        -o jsonpath='{.spec.ports[0].nodePort}'
    )"
  fi

  if [[ -z "${node_port}" ]]; then
    echo "ERROR: cannot determine Prometheus NodePort on cluster${cluster}"
    exit 1
  fi

  echo "API server:         ${api_server}"
  echo "Node InternalIP:    ${member_ip}"
  echo "Prometheus Service: ${service_name}"
  echo "Prometheus port:    ${node_port}"
  echo "Federation target:  ${member_ip}:${node_port}"

  # ----------------------------------------------------------
  # Add federation job to management-values.yaml
  # ----------------------------------------------------------

  cat >> management-values.yaml <<EOF
      - job_name: federation-cluster${cluster}
        scrape_interval: 30s
        scrape_timeout: 20s
        metrics_path: /federate
        honor_labels: true
        honor_timestamps: true

        params:
          'match[]':
            - '{__name__="container_cpu_usage_seconds_total",namespace="camca-motivation",container!="",container!="POD",image!=""}'
            - '{__name__="kube_pod_container_resource_requests",namespace="camca-motivation",resource="cpu",unit="core"}'
            - '{__name__="kube_deployment_spec_replicas",namespace="camca-motivation"}'
            - '{__name__="kube_deployment_status_replicas_available",namespace="camca-motivation"}'
            - '{__name__="kube_deployment_status_replicas_ready",namespace="camca-motivation"}'
            - '{__name__="kube_pod_status_ready",namespace="camca-motivation",condition="true"}'

        static_configs:
          - targets:
              - '${member_ip}:${node_port}'
            labels:
              source_cluster: cluster${cluster}

EOF
done

# ============================================================
# 4. Show generated management values
# ============================================================

echo
echo "============================================================"
echo "Generated management-values.yaml"
echo "============================================================"

cat management-values.yaml

# ============================================================
# 5. Install management Prometheus on cluster0
# ============================================================

echo
echo "============================================================"
echo "Installing management Prometheus on cluster0"
echo "============================================================"

kubectl config use-context cluster0

helm upgrade --install prometheus \
  prometheus-community/kube-prometheus-stack \
  --version 87.6.0 \
  --namespace monitoring \
  --create-namespace \
  --kube-context cluster0 \
  --values management-values.yaml \
  --wait \
  --timeout 15m

# ============================================================
# 6. Display final configuration
# ============================================================

echo
echo "============================================================"
echo "Installation completed"
echo "============================================================"

echo
echo "Member Prometheus configuration:"

for cluster in 1 2 3 4 5; do
  echo
  echo "cluster${cluster}:"

  kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    --namespace monitoring \
    get prometheus \
    -o custom-columns=NAME:.metadata.name,SCRAPE:.spec.scrapeInterval
done

echo
echo "Management Prometheus:"

kubectl \
  --context cluster0 \
  --namespace monitoring \
  get prometheus \
  -o custom-columns=NAME:.metadata.name,SCRAPE:.spec.scrapeInterval

echo
echo "Management values file:"
echo "$(pwd)/management-values.yaml"

echo
echo "To inspect federation targets, run:"
echo
echo "kubectl --context cluster0 -n monitoring port-forward \\"
echo "  service/prometheus-kube-prometheus-stack-prometheus 9090:9090"
echo
echo "Then open:"
echo "http://127.0.0.1:9090/targets"