#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем, что API-серверы запущены с политикой и выходом аудита."
API_PODS=$(kubectl -n kube-system get pods -l component=kube-apiserver -o name)
echo "API-серверы: $API_PODS"
if [ -z "$API_PODS" ]; then
  echo "ОШИБКА: API-серверы по метке component=kube-apiserver не найдены."
  exit 1
fi
for API_POD in $API_PODS; do
  AUDIT_ARGUMENTS=$(kubectl -n kube-system get "$API_POD" -o jsonpath='{.spec.containers[?(@.name=="kube-apiserver")].command} {.spec.containers[?(@.name=="kube-apiserver")].args}')
  echo "Команда и аргументы $API_POD: $AUDIT_ARGUMENTS"
  if [[ "$AUDIT_ARGUMENTS" != *'--audit-policy-file'* ]]; then
    echo "ОШИБКА: у $API_POD не задана политика аудита --audit-policy-file."
    exit 1
  fi
  if [[ "$AUDIT_ARGUMENTS" != *'--audit-log-path'* && "$AUDIT_ARGUMENTS" != *'--audit-webhook-config-file'* ]]; then
    echo "ОШИБКА: у $API_POD не настроен выход аудита в файл/stdout или webhook."
    exit 1
  fi
done
echo "Аудит настроен в аргументах запуска. Полнота записей будет проверена по выгрузке."

echo "Создаём маркер и выполняем операции для аудита пункта 56."
kubectl create namespace pmi-56
kubectl -n pmi-56 create serviceaccount observer
kubectl -n pmi-56 create configmap audit-marker --from-literal=value=before
kubectl -n pmi-56 get configmap audit-marker
kubectl -n pmi-56 patch configmap audit-marker --type=merge -p '{"data":{"value":"after"}}'
echo "Проверяем отказ на чтение маркера от имени учётной записи без прав."
if RESULT=$(kubectl --as=system:serviceaccount:pmi-56:observer -n pmi-56 get configmap audit-marker 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: чтение неожиданно разрешено."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'forbidden'* || "$RESULT" != *'cannot get resource "configmaps"'* ]]; then
  echo "ОШИБКА: отказ не подтверждает проверяемую авторизацию."
  exit 1
fi
kubectl -n pmi-56 delete configmap audit-marker
echo "События сформированы. Выгрузите аудит всех API-серверов за время этого запуска по README."
