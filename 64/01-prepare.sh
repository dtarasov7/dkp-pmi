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
    image: busybox:1.36.1
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
    image: busybox:1.36.1
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
