#!/usr/bin/env bash
set -euo pipefail

echo "Шаг 1. Проверяем запрет изменения Role учётной записью observer."

BEFORE=$(kubectl -n pmi-36 get role target -o jsonpath='{.rules[0].verbs[*]}')
echo "Значение до запроса: $BEFORE"
if [ "$BEFORE" != "get" ]; then
  echo "ОШИБКА: требуется чистое исходное состояние."
  exit 1
fi
if RESULT=$(kubectl --as=system:serviceaccount:pmi-36:observer -n pmi-36 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list"]}]}' 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: изменение без разрешения прошло."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'is forbidden: User "system:serviceaccount:pmi-36:observer" cannot patch resource'* ]]; then
  echo "ОШИБКА: получен другой отказ."
  exit 1
fi
AFTER=$(kubectl -n pmi-36 get role target -o jsonpath='{.rules[0].verbs[*]}')
echo "Значение после отказа: $AFTER"
if [ "$AFTER" != "$BEFORE" ]; then
  echo "ОШИБКА: политика изменилась."
  exit 1
fi
echo "Шаг 2. Разрешённое изменение Role учётной записью editor."
kubectl --as=system:serviceaccount:pmi-36:editor -n pmi-36 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list"]}]}'
AFTER=$(kubectl -n pmi-36 get role target -o jsonpath='{.rules[0].verbs[*]}')
echo "Значение после разрешённого запроса: $AFTER"
if [ "$AFTER" != "get list" ]; then
  echo "ОШИБКА: разрешённое изменение не применено."
  exit 1
fi

echo "Шаг 3. Проверяем запрет изменения SecurityPolicy учётной записью observer."
BEFORE=$(kubectl get securitypolicy pmi-36 -o jsonpath='{.spec.policies.allowHostNetwork}')
echo "Значение до запроса: $BEFORE"
if [ "$BEFORE" != "false" ]; then
  echo "ОШИБКА: требуется чистое исходное состояние."
  exit 1
fi
if RESULT=$(kubectl --as=system:serviceaccount:pmi-36:observer patch securitypolicy pmi-36 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":true}}}' 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: изменение без разрешения прошло."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'is forbidden: User "system:serviceaccount:pmi-36:observer" cannot patch resource'* ]]; then
  echo "ОШИБКА: получен другой отказ."
  exit 1
fi
AFTER=$(kubectl get securitypolicy pmi-36 -o jsonpath='{.spec.policies.allowHostNetwork}')
echo "Значение после отказа: $AFTER"
if [ "$AFTER" != "$BEFORE" ]; then
  echo "ОШИБКА: политика изменилась."
  exit 1
fi
echo "Шаг 4. Разрешённое изменение SecurityPolicy учётной записью editor."
kubectl --as=system:serviceaccount:pmi-36:editor patch securitypolicy pmi-36 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":true}}}'
AFTER=$(kubectl get securitypolicy pmi-36 -o jsonpath='{.spec.policies.allowHostNetwork}')
echo "Значение после разрешённого запроса: $AFTER"
if [ "$AFTER" != "true" ]; then
  echo "ОШИБКА: разрешённое изменение не применено."
  exit 1
fi
echo "УСПЕХ: авторизация блокирует запрещённые изменения и допускает разрешённые. Для аудита выполните шаги README."
