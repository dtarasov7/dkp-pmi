#!/usr/bin/env bash
set -euo pipefail

: "${APP_HOST:?Укажите DNS-имя тестового Ingress в APP_HOST}"
: "${TLS_CA:?Укажите файл доверенного CA тестового Ingress в TLS_CA}"
for POD in client server; do
  CONTAINERS=$(kubectl -n pmi-41 get pod "$POD" -o jsonpath='{.spec.containers[*].name}')
  echo "Контейнеры Pod $POD: $CONTAINERS"
  if [[ " $CONTAINERS " != *' istio-proxy '* ]]; then
    echo "ОШИБКА: sidecar не внедрён."
    exit 1
  fi
done
EXTERNAL_HOST=$(kubectl -n pmi-41 get serviceentry external-https -o jsonpath='{.spec.hosts[0]}')
echo "Внешний сервер ServiceEntry: $EXTERNAL_HOST"
echo "Генерируем трафик для графа Kiali."
for ATTEMPT in {1..30}; do
  echo "Серия запросов $ATTEMPT из 30."
  INTERNAL_BODY=$(kubectl -n pmi-41 exec client -c app -- curl --fail --show-error --silent --max-time 10 http://server:8080/)
  echo "Ответ внутреннего сервиса: $INTERNAL_BODY"
  if [ "$INTERNAL_BODY" != pmi-ok ]; then
    echo "ОШИБКА: внутренний запрос не достиг тестового сервера."
    exit 1
  fi
  HTTP_CODE=$(kubectl -n pmi-41 exec client -c app -- curl --fail --show-error --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "https://$EXTERNAL_HOST/")
  echo "Ответ внешнего HTTPS-сервера: $HTTP_CODE"
  if [[ "$HTTP_CODE" != 2* ]]; then
    echo "ОШИБКА: внешний сервер не вернул ожидаемый успешный ответ."
    exit 1
  fi
  INGRESS_BODY=$(curl --fail --show-error --silent --max-time 10 --cacert "$TLS_CA" "https://$APP_HOST/")
  echo "Ответ через HTTPS Ingress: $INGRESS_BODY"
  if [ "$INGRESS_BODY" != pmi-ok ]; then
    echo "ОШИБКА: внешний запрос не достиг тестового сервера."
    exit 1
  fi
  sleep 2
done
kubectl -n pmi-41 get peerauthentication,destinationrule,serviceentry,ingress
echo "Трафик сформирован. Подтвердите mTLS на графе Kiali и отдельно внешний HTTPS по README."
