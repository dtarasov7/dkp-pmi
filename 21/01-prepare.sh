#!/usr/bin/env bash
set -euo pipefail

echo "Создаём тестовое развёртывание: 2 реплики, CPU 100m, память 64Mi на контейнер."
kubectl create namespace pmi-21
kubectl create -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: resource-limits
  namespace: pmi-21
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pmi-21-resources
  template:
    metadata:
      labels:
        app: pmi-21-resources
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: redos_sudo
        imagePullPolicy: IfNotPresent
        command: ["sleep", "86400"]
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
YAML
kubectl -n pmi-21 rollout status deployment/resource-limits --timeout=180s
kubectl -n pmi-21 get deployment resource-limits
kubectl -n pmi-21 get pods -l app=pmi-21-resources -o wide
echo "Подготовка завершена. Проверка CPU и памяти выполняется в 02-check.sh."
