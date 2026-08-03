#!/usr/bin/env bash
set -euo pipefail

KARMADA_KUBECONFIG=/etc/karmada/karmada-apiserver.config

# Create namespace in Karmada and member clusters

kubectl \
  --kubeconfig "${KARMADA_KUBECONFIG}" \
  create namespace camca-motivation \
  --dry-run=client \
  -o yaml |
kubectl \
  --kubeconfig "${KARMADA_KUBECONFIG}" \
  apply -f -

for cluster in 1 2 3 4 5 6; do
  kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    create namespace camca-motivation \
    --dry-run=client \
    -o yaml |
  kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    apply -f -
done

# ============================================================
# Create application manifest
# ============================================================

cat > camca-application.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
  namespace: camca-motivation
  labels:
    app: php-apache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
        - name: php-apache
          image: registry.k8s.io/hpa-example:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80
          resources:
            requests:
              cpu: 200m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
  namespace: camca-motivation
spec:
  selector:
    app: php-apache
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF

# ============================================================
# Propagate one identical Deployment to every member cluster
# ============================================================

cat > camca-propagation-policy.yaml <<'EOF'
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: php-apache
  namespace: camca-motivation
spec:
  resourceSelectors:
    - apiVersion: apps/v1
      kind: Deployment
      name: php-apache
    - apiVersion: v1
      kind: Service
      name: php-apache

  placement:
    clusterAffinity:
      clusterNames:
        - cluster1
        - cluster2
        - cluster3
        - cluster4
        - cluster5
        - cluster6

    replicaScheduling:
      replicaSchedulingType: Duplicated
EOF

kubectl \
  --kubeconfig "${KARMADA_KUBECONFIG}" \
  apply -f camca-propagation-policy.yaml

kubectl \
  --kubeconfig "${KARMADA_KUBECONFIG}" \
  apply -f camca-application.yaml

# ============================================================
# Wait for application in all member clusters
# ============================================================

for cluster in 1 2 3 4 5 6; do
  echo
  echo "Waiting for php-apache on cluster${cluster}"

  until kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    --namespace camca-motivation \
    get deployment php-apache \
    >/dev/null 2>&1; do
    sleep 5
  done

  kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    --namespace camca-motivation \
    rollout status deployment/php-apache \
    --timeout=10m
done

echo
echo "============================================================"
echo "Application deployed to all six clusters"
echo "============================================================"

for cluster in 1 2 3 4 5 6; do
  echo
  echo "cluster${cluster}:"

  kubectl \
    --kubeconfig "$HOME/.kube/cluster${cluster}" \
    --namespace camca-motivation \
    get deployment,pod,service \
    -l app=php-apache \
    -o wide
done