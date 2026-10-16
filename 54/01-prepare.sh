#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем готовность модулей Deckhouse."
if MODULE_PHASE=$(kubectl get module "admission-policy-engine" -o jsonpath='{.status.phase}'); then
  echo "Модуль admission-policy-engine: $MODULE_PHASE"
else
  echo "ОШИБКА: не удалось получить состояние модуля admission-policy-engine. Вывод Kubernetes приведён выше."
  exit 1
fi
if [ "$MODULE_PHASE" != Ready ]; then
  echo "ОШИБКА: модуль admission-policy-engine не готов. Выполните kubectl get module admission-policy-engine -o yaml и устраните указанную там причину."
  exit 1
fi

echo "Показываем действующие настройки встроенных политик."
kubectl get moduleconfig admission-policy-engine -o yaml
echo "Проверяем наличие webhook Gatekeeper."
WEBHOOKS=$(kubectl get validatingwebhookconfigurations -o jsonpath='{range .items[*].webhooks[*]}{.name}{"\n"}{end}')
echo "$WEBHOOKS"
if [[ "$WEBHOOKS" != *'validation.gatekeeper.sh'* ]]; then
  echo "ОШИБКА: webhook validation.gatekeeper.sh не зарегистрирован; проверка запретов Gatekeeper невозможна."
  exit 1
fi

echo "Создаём три пространства с разными уровнями защиты Gatekeeper."
for PROFILE in privileged baseline restricted; do
  kubectl create namespace "pmi-54-$PROFILE"
  kubectl label namespace "pmi-54-$PROFILE" "security.deckhouse.io/pod-policy=$PROFILE" security.deckhouse.io/pod-policy-action=deny
done
kubectl get namespace pmi-54-privileged pmi-54-baseline pmi-54-restricted --show-labels
echo "Подготовка завершена."
