#!/usr/bin/env bash
set -euo pipefail

echo "Шаг 1. Проверяем доступ каждого арендатора к своим и чужим данным."
for TENANT in a b; do
  OTHER=a
  if [ "$TENANT" = a ]; then
    OTHER=b
  fi
  kubectl --as="system:serviceaccount:pmi-64-$TENANT:tenant" -n "pmi-64-$TENANT" get configmap private
  if RESULT=$(kubectl --as="system:serviceaccount:pmi-64-$TENANT:tenant" -n "pmi-64-$OTHER" get configmap private 2>&1); then
    echo "$RESULT"
    echo "ОШИБКА: доступ к данным другого арендатора разрешён."
    exit 1
  fi
  echo "$RESULT"
  if [[ "$RESULT" != *'forbidden'* || "$RESULT" != *'cannot get resource "configmaps"'* ]]; then
    echo "ОШИБКА: получен другой отказ."
    exit 1
  fi
done
IP_A=$(kubectl -n pmi-64-a get pod server -o jsonpath='{.status.podIP}')
IP_B=$(kubectl -n pmi-64-b get pod server -o jsonpath='{.status.podIP}')
echo "Адреса серверов: A=$IP_A, B=$IP_B"
echo "Шаг 2. До изоляции HTTP должен работать в обоих направлениях."
kubectl -n pmi-64-a exec client -c app -- curl --noproxy '*' --fail --show-error --silent --connect-timeout 3 --max-time 3 "http://$IP_B:8080/"
kubectl -n pmi-64-b exec client -c app -- curl --noproxy '*' --fail --show-error --silent --connect-timeout 3 --max-time 3 "http://$IP_A:8080/"
echo "Шаг 3. Разрешаем каждому арендатору трафик только внутри своего namespace."
for TENANT in a b; do
  kubectl create -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolation
  namespace: pmi-64-$TENANT
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
YAML
done
echo "Шаг 4. Проверяем разрешённые и запрещённые HTTP-запросы."
for TENANT in a b; do
  OWN_IP=$IP_A
  OTHER_IP=$IP_B
  if [ "$TENANT" = b ]; then
    OWN_IP=$IP_B
    OTHER_IP=$IP_A
  fi
  echo "Внутри арендатора $TENANT запрос должен проходить."
  kubectl -n "pmi-64-$TENANT" exec client -c app -- curl --noproxy '*' --fail --show-error --silent --connect-timeout 3 --max-time 3 "http://$OWN_IP:8080/"
  for ATTEMPT in {1..10}; do
    echo "Запрос к другому арендатору: попытка $ATTEMPT из 10."
    # Сохраняем код команды: 0 — доступ есть, 28 — тайм-аут.
    CURL_STATUS=0
    kubectl -n "pmi-64-$TENANT" exec client -c app -- curl --noproxy '*' --fail --show-error --silent --max-time 3 "http://$OTHER_IP:8080/" || CURL_STATUS=$?
    echo "Код запроса: $CURL_STATUS"
    if [ "$CURL_STATUS" -ne 0 ]; then
      break
    fi
    sleep 2
  done
  if [ "$CURL_STATUS" -ne 28 ]; then
    echo "ОШИБКА: ожидался тайм-аут 28. Другие ошибки не подтверждают изоляцию."
    exit 1
  fi
  echo "После подтверждения запрета повторяем разрешённый запрос внутри арендатора."
  kubectl -n "pmi-64-$TENANT" exec client -c app -- curl --noproxy '*' --fail --show-error --silent --connect-timeout 3 --max-time 3 "http://$OWN_IP:8080/"
done
echo "Шаг 5. HTTP readinessProbe должна подтверждать готовность обоих серверов."
kubectl -n pmi-64-a wait --for=condition=Ready pod/server --timeout=60s
kubectl -n pmi-64-b wait --for=condition=Ready pod/server --timeout=60s
echo "УСПЕХ: проверены RBAC и двусторонняя сетевая изоляция тестовых арендаторов. Границы проверки указаны в README."
