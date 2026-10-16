#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем взаимное разделение арендаторов по API."
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
echo "До изоляции проверяем доступность в обоих направлениях."
kubectl -n pmi-64-a exec client -c app -- wget -T 3 -qO- "http://$IP_B:8080/"
kubectl -n pmi-64-b exec client -c app -- wget -T 3 -qO- "http://$IP_A:8080/"
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
for TENANT in a b; do
  OWN_IP=$IP_A
  OTHER_IP=$IP_B
  if [ "$TENANT" = b ]; then
    OWN_IP=$IP_B
    OTHER_IP=$IP_A
  fi
  echo "Внутри арендатора $TENANT запрос должен проходить."
  kubectl -n "pmi-64-$TENANT" exec client -c app -- wget -T 3 -qO- "http://$OWN_IP:8080/"
  BLOCKED=false
  for ATTEMPT in {1..20}; do
    if RESULT=$(kubectl -n "pmi-64-$TENANT" exec client -c app -- wget -T 3 -qO- "http://$OTHER_IP:8080/" 2>&1); then
      echo "Попытка $ATTEMPT: ждём применения политики. Ответ: $RESULT"
    else
      echo "$RESULT"
      if [[ "$RESULT" != *'wget:'* || "$RESULT" != *'timed out'* ]]; then
        echo "ОШИБКА: получен другой отказ."
        exit 1
      fi
      BLOCKED=true
      break
    fi
    sleep 2
  done
  if [ "$BLOCKED" != true ]; then
    echo "ОШИБКА: межарендный доступ не заблокирован."
    exit 1
  fi
  echo "После подтверждения запрета повторяем разрешённый запрос внутри арендатора."
  kubectl -n "pmi-64-$TENANT" exec client -c app -- wget -T 3 -qO- "http://$OWN_IP:8080/"
done
kubectl -n pmi-64-a exec server -c app -- wget -T 3 -qO- http://127.0.0.1:8080/
kubectl -n pmi-64-b exec server -c app -- wget -T 3 -qO- http://127.0.0.1:8080/
echo "УСПЕХ: проверены RBAC и двусторонняя сетевая изоляция тестовых арендаторов. Границы проверки указаны в README."
