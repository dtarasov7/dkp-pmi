#!/usr/bin/env bash
set -euo pipefail

echo "Сетевую изоляцию проверяем на установленном Cilium; Hubble включён."
echo "Сначала проверим разрешённый обмен, затем запрет после применения NetworkPolicy."

echo "Создаём двух тестовых арендаторов."
kubectl create namespace pmi-64-a
kubectl -n pmi-64-a create serviceaccount tenant
kubectl -n pmi-64-a create configmap private --from-literal=owner=a
kubectl create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: pmi-64-a
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
  namespace: pmi-64-a
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
kubectl -n pmi-64-a wait --for=condition=Ready pod --all --timeout=180s
kubectl create -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-reader
  namespace: pmi-64-a
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-reader
  namespace: pmi-64-a
subjects:
- kind: ServiceAccount
  name: tenant
  namespace: pmi-64-a
roleRef:
  kind: Role
  name: tenant-reader
  apiGroup: rbac.authorization.k8s.io
YAML
kubectl create namespace pmi-64-b
kubectl -n pmi-64-b create serviceaccount tenant
kubectl -n pmi-64-b create configmap private --from-literal=owner=b
kubectl create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: pmi-64-b
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
  namespace: pmi-64-b
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
kubectl -n pmi-64-b wait --for=condition=Ready pod --all --timeout=180s
kubectl create -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-reader
  namespace: pmi-64-b
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-reader
  namespace: pmi-64-b
subjects:
- kind: ServiceAccount
  name: tenant
  namespace: pmi-64-b
roleRef:
  kind: Role
  name: tenant-reader
  apiGroup: rbac.authorization.k8s.io
YAML
