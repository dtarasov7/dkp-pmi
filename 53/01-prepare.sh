#!/usr/bin/env bash
set -euo pipefail

echo "На стенде используются включённые Cilium и Hubble. Показываем опубликованные адреса."
kubectl -n d8-cni-cilium get ingress
echo "Перед проверкой откройте Hubble UI из меню платформы или по адресу выше."

echo "Создаём клиент и HTTP-сервер для наблюдения в Hubble."
kubectl create namespace pmi-53
kubectl create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: pmi-53
  labels:
    app: server
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36.1
    command: ["sh", "-c", "mkdir -p /tmp/www; echo pmi-ok > /tmp/www/index.html; httpd -f -p 8080 -h /tmp/www"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    readinessProbe:
      httpGet:
        path: /
        port: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: pmi-53
  labels:
    app: client
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36.1
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
YAML
kubectl -n pmi-53 wait --for=condition=Ready pod --all --timeout=180s
