#!/bin/bash

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
6 300s
EOF

sleep 60

# Start management values file

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

# Federation target for member clusters

for cluster in 1 2 3 4 5 6; do

  kubeconfig="$HOME/.kube/cluster${cluster}"

  member_ip="$(
    kubectl \
      --kubeconfig "${kubeconfig}" \
      get nodes \
      -l node-role.kubernetes.io/control-plane \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
  )"

  if [[ -z "${member_ip}" ]]; then
    echo "ERROR: cannot determine a node InternalIP for cluster${cluster}"
    exit 1
  fi

  service_name="$(
  kubectl \
    --kubeconfig "${kubeconfig}" \
    --namespace monitoring \
    get service \
    -l app=kube-prometheus-stack-prometheus \
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

  if [[ -z "${node_port}" ]]; then
    echo "ERROR: cannot determine Prometheus NodePort on cluster${cluster}"
    exit 1
  fi

  echo "Node InternalIP:    ${member_ip}"
  echo "Prometheus Service: ${service_name}"
  echo "Prometheus port:    ${node_port}"
  echo "Federation target:  ${member_ip}:${node_port}"

  # Add federation job to management-values.yaml

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

# Install management Prometheus on cluster0

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
  --values management-values.yaml

# Display final configuration

sleep 60

# ============================================================
# Check installation and display final configuration
# ============================================================

check_monitoring_pods() {
  cluster_name="$1"
  shift

  echo
  echo "============================================================"
  echo "Checking monitoring Pods on ${cluster_name}"
  echo "============================================================"

  for attempt in $(seq 1 120); do
    pods="$(
      kubectl "$@" \
        --namespace monitoring \
        get pods \
        --no-headers \
        2>/dev/null || true
    )"

    if [[ -n "${pods}" ]]; then
      unhealthy_pods="$(
        printf '%s\n' "${pods}" |
        awk '
          {
            split($2, ready, "/")

            if ($3 != "Running" && $3 != "Completed") {
              print
            } else if ($3 == "Running" && ready[1] != ready[2]) {
              print
            }
          }
        '
      )"

      if [[ -z "${unhealthy_pods}" ]]; then
        echo "All monitoring Pods on ${cluster_name} are ready."

        kubectl "$@" \
          --namespace monitoring \
          get pods \
          -o wide

        return 0
      fi
    fi

    echo "Waiting for monitoring Pods on ${cluster_name}... (${attempt}/120)"
    sleep 5
  done

  echo
  echo "ERROR: monitoring Pods on ${cluster_name} did not become ready."

  kubectl "$@" \
    --namespace monitoring \
    get pods \
    -o wide || true

  echo
  echo "Recent events on ${cluster_name}:"

  kubectl "$@" \
    --namespace monitoring \
    get events \
    --sort-by='.lastTimestamp' |
  tail -n 30 || true

  exit 1
}

# Check member clusters

for cluster in 1 2 3 4 5 6; do
  check_monitoring_pods \
    "cluster${cluster}" \
    --kubeconfig "$HOME/.kube/cluster${cluster}"
done

# Check management cluster

check_monitoring_pods \
  "cluster0" \
  --context cluster0

# Display final configuration

echo
echo "============================================================"
echo "Installation completed"
echo "============================================================"

echo
echo "Member Prometheus configuration:"

for cluster in 1 2 3 4 5 6; do
  echo
  echo "cluster${cluster}:"

  kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    --namespace monitoring \
    get prometheus \
    -o custom-columns=NAME:.metadata.name,SCRAPE:.spec.scrapeInterval
done

echo
echo "Management Prometheus configuration:"

kubectl \
  --context cluster0 \
  --namespace monitoring \
  get prometheus \
  -o custom-columns=NAME:.metadata.name,SCRAPE:.spec.scrapeInterval

echo
echo "Management Prometheus Service:"

kubectl \
  --context cluster0 \
  --namespace monitoring \
  get service \
  -l app=kube-prometheus-stack-prometheus

echo
echo "Management values file:"
echo "$(pwd)/management-values.yaml"