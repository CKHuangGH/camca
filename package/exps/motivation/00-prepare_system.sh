#!/bin/bash

curl -s https://raw.githubusercontent.com/karmada-io/karmada/master/hack/install-cli.sh | sudo INSTALL_CLI_VERSION=1.18.1 bash

kubectl config use-context cluster0

# for i in $(cat node_exec)
# do
#     ssh root@$i kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
# done

karmadactl init

for i in $(seq 30 -1 1); do
    printf "\rCountdown: %2d seconds" "${i}"
    sleep 1
done

cluster=1
for i in $(cat cp_node_list_without_management)
do
    karmadactl --kubeconfig /etc/karmada/karmada-apiserver.config  join cluster$cluster --cluster-kubeconfig=$HOME/.kube/cluster$cluster &
	cluster=$((cluster+1))
done

sleep 30

helm repo add prometheus-community httpsprometheus-community.github.iohelm-charts
helm repo update
helm install prom prometheus-communitykube-prometheus-stack 
  --version 87.6.0 
  --namespace monitoring 
  --create-namespace 
  --set grafana.enabled=false 
  --set alertmanager.enabled=false 
  --set prometheus.service.type=NodePort 
  --set prometheus.prometheusSpec.scrapeInterval=5s 
  --set prometheus.prometheusSpec.enableAdminAPI=true 
  --set prometheus.prometheusSpec.resources.requests.cpu=1000m 
  --set prometheus.prometheusSpec.resources.requests.memory=1024Mi

for i in $(cat cp_node_list_without_management)
do
    helm repo add prometheus-community httpsprometheus-community.github.iohelm-charts
    helm repo update
    helm install prom prometheus-communitykube-prometheus-stack 
    --version 87.6.0 
    --namespace monitoring 
    --create-namespace 
    --set grafana.enabled=false 
    --set alertmanager.enabled=false 
    --set prometheus.service.type=NodePort 
    --set prometheus.prometheusSpec.scrapeInterval=5s 
    --set prometheus.prometheusSpec.enableAdminAPI=true 
    --set prometheus.prometheusSpec.resources.requests.cpu=1000m 
    --set prometheus.prometheusSpec.resources.requests.memory=1024Mi
done