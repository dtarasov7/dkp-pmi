#!/usr/bin/env bash
set -euo pipefail

: "${APP_HOST:?Укажите DNS-имя тестового Ingress в APP_HOST}"
: "${EXTERNAL_HOST:?Укажите DNS-имя внешнего HTTPS-сервера в EXTERNAL_HOST}"
: "${INGRESS_CLASS:?Укажите класс настроенного Ingress с Istio sidecar}"
: "${TLS_CERT:?Укажите путь к сертификату тестового Ingress}"
: "${TLS_KEY:?Укажите путь к ключу тестового Ingress}"
echo "Проверяем готовность модулей Deckhouse."
if MODULE_PHASE=$(kubectl get module "istio" -o jsonpath='{.status.phase}'); then
  echo "Модуль istio: $MODULE_PHASE"
else
  echo "ОШИБКА: не удалось получить состояние модуля istio. Вывод Kubernetes приведён выше."
  exit 1
fi
if [ "$MODULE_PHASE" != Ready ]; then
  echo "ОШИБКА: модуль istio не готов. Выполните kubectl get module istio -o yaml и устраните указанную там причину."
  exit 1
fi

echo "Проверяем необходимые поля API networking.istio.io/v1beta1."
for FIELD in destinationrule.spec.trafficPolicy.tls.mode serviceentry.spec.hosts serviceentry.spec.ports; do
  if FIELD_DESCRIPTION=$(kubectl explain "$FIELD" --api-version=networking.istio.io/v1beta1); then
    echo "$FIELD_DESCRIPTION"
  else
    echo "ОШИБКА: API networking.istio.io/v1beta1 не предоставляет поле $FIELD или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
    exit 1
  fi
done

echo "Проверяем необходимые поля API security.istio.io/v1beta1."
if FIELD_DESCRIPTION=$(kubectl explain "peerauthentication.spec.mtls.mode" --api-version=security.istio.io/v1beta1); then
  echo "$FIELD_DESCRIPTION"
else
  echo "ОШИБКА: API security.istio.io/v1beta1 не предоставляет поле peerauthentication.spec.mtls.mode или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
  exit 1
fi

echo "Проверяем файлы сертификата и ключа тестового Ingress."
for TLS_FILE in "$TLS_CERT" "$TLS_KEY"; do
  echo "Файл: $TLS_FILE"
  if [ ! -r "$TLS_FILE" ]; then
    echo "ОШИБКА: файл не существует или недоступен для чтения."
    exit 1
  fi
done
echo "Проверяем, что выбранный Ingress-контроллер подключён к Istio."
CONTROLLER_NAMES=$(kubectl get ingressnginxcontrollers.deckhouse.io -o name)
CONTROLLER_FOUND=false
for CONTROLLER in $CONTROLLER_NAMES; do
  CONTROLLER_CLASS=$(kubectl get "$CONTROLLER" -o jsonpath='{.spec.ingressClass}')
  if [ "$CONTROLLER_CLASS" = "$INGRESS_CLASS" ]; then
    CONTROLLER_FOUND=true
    SIDECAR_ENABLED=$(kubectl get "$CONTROLLER" -o jsonpath='{.spec.enableIstioSidecar}')
    echo "Контроллер: $CONTROLLER; класс: $CONTROLLER_CLASS; Istio sidecar: $SIDECAR_ENABLED"
    if [ "$SIDECAR_ENABLED" != true ]; then
      echo "ОШИБКА: для выбранного IngressNginxController не включён spec.enableIstioSidecar; STRICT mTLS не пропустит запрос к Pod."
      exit 1
    fi
  fi
done
if [ "$CONTROLLER_FOUND" != true ]; then
  echo "ОШИБКА: IngressNginxController для класса $INGRESS_CLASS не найден. Укажите его spec.ingressClass в INGRESS_CLASS."
  exit 1
fi
echo "Адреса интерфейсов Istio/Kiali:"
kubectl -n d8-istio get ingress

echo "Создаём namespace с инъекцией sidecar Istio."
kubectl create namespace pmi-41
kubectl label namespace pmi-41 istio-injection=enabled
kubectl -n pmi-41 create secret tls ingress-tls --cert="$TLS_CERT" --key="$TLS_KEY"
kubectl create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: pmi-41
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
  namespace: pmi-41
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
    image: curlimages/curl:8.12.1
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
YAML
kubectl -n pmi-41 wait --for=condition=Ready pod --all --timeout=180s

kubectl create -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: server
  namespace: pmi-41
spec:
  selector:
    app: server
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: strict
  namespace: pmi-41
spec:
  mtls:
    mode: STRICT
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: internal-mtls
  namespace: pmi-41
spec:
  host: server.pmi-41.svc.cluster.local
  exportTo: ["*"]
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-https
  namespace: pmi-41
spec:
  hosts: ["$EXTERNAL_HOST"]
  exportTo: ["."]
  location: MESH_EXTERNAL
  resolution: DNS
  ports:
  - number: 443
    name: https
    protocol: HTTPS
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  namespace: pmi-41
  annotations:
    nginx.ingress.kubernetes.io/service-upstream: "true"
    nginx.ingress.kubernetes.io/upstream-vhost: server.pmi-41.svc.cluster.local
spec:
  ingressClassName: "$INGRESS_CLASS"
  tls:
  - hosts: ["$APP_HOST"]
    secretName: ingress-tls
  rules:
  - host: "$APP_HOST"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: server
            port:
              number: 8080
YAML
echo "Подготовка завершена. Дождитесь синхронизации конфигурации Istio."
