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
    image: nginx
    imagePullPolicy: IfNotPresent
    command: ["sh", "-ec"]
    args:
    - |
      mkdir -p /tmp/pmi-nginx
      cat > /tmp/pmi-nginx/nginx.conf <<'NGINX'
      worker_processes 1;
      pid /tmp/pmi-nginx/nginx.pid;
      error_log stderr notice;
      events { worker_connections 64; }
      http {
        access_log off;
        client_body_temp_path /tmp/pmi-nginx/client;
        proxy_temp_path /tmp/pmi-nginx/proxy;
        fastcgi_temp_path /tmp/pmi-nginx/fastcgi;
        uwsgi_temp_path /tmp/pmi-nginx/uwsgi;
        scgi_temp_path /tmp/pmi-nginx/scgi;
        server {
          listen 8080;
          location / {
            default_type text/plain;
            return 200 "pmi-ok\n";
          }
        }
      }
      NGINX
      exec nginx -e stderr -c /tmp/pmi-nginx/nginx.conf -g 'daemon off;'
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    readinessProbe:
      httpGet:
        path: /
        port: 8080
      periodSeconds: 2
      timeoutSeconds: 1
      failureThreshold: 2
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
    image: redos_sudo
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
YAML
kubectl -n pmi-53 wait --for=condition=Ready pod --all --timeout=180s
