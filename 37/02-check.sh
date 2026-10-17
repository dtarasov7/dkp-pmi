#!/usr/bin/env bash
set -euo pipefail

echo "Шаг 1. Пока editor имеет право изменения, PATCH обеих политик проходит."
kubectl --as=system:serviceaccount:pmi-37:editor -n pmi-37 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list"]}]}'
kubectl --as=system:serviceaccount:pmi-37:editor patch securitypolicy pmi-37 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":true}}}'
ROLE_BEFORE=$(kubectl -n pmi-37 get role target -o jsonpath='{.rules[0].verbs[*]}')
POLICY_BEFORE=$(kubectl get securitypolicy pmi-37 -o jsonpath='{.spec.policies.allowHostNetwork}')
echo "После разрешённых изменений: Role=$ROLE_BEFORE; allowHostNetwork=$POLICY_BEFORE"
if [ "$ROLE_BEFORE" != 'get list' ] || [ "$POLICY_BEFORE" != true ]; then
  echo "ОШИБКА: исходные разрешённые изменения не применились."
  exit 1
fi

echo "Шаг 2. Отзываем у editor разрешение на изменение. Отдельные права чтения сохраняются."
kubectl -n pmi-37 delete rolebinding editor
kubectl delete clusterrolebinding pmi-37-editor
kubectl --as=system:serviceaccount:pmi-37:editor -n pmi-37 get role target
kubectl --as=system:serviceaccount:pmi-37:editor get securitypolicy pmi-37

echo "Шаг 3. Та же учётная запись пытается вернуть Role к исходному значению."
if RESULT=$(kubectl --as=system:serviceaccount:pmi-37:editor -n pmi-37 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get"]}]}' 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: изменение Role прошло после отзыва разрешения."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'is forbidden: User "system:serviceaccount:pmi-37:editor" cannot patch resource "roles"'* ]]; then
  echo "ОШИБКА: ожидался запрет PATCH, а не ошибка GET или другая причина."
  exit 1
fi
ROLE_AFTER=$(kubectl -n pmi-37 get role target -o jsonpath='{.rules[0].verbs[*]}')
echo "Role до запрещённого PATCH: $ROLE_BEFORE; после: $ROLE_AFTER"
if [ "$ROLE_AFTER" != "$ROLE_BEFORE" ]; then
  echo "ОШИБКА: заблокированное изменение затронуло Role."
  exit 1
fi

echo "Шаг 4. Проверяем блокировку возврата allowHostNetwork в SecurityPolicy."
if RESULT=$(kubectl --as=system:serviceaccount:pmi-37:editor patch securitypolicy pmi-37 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":false}}}' 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: изменение SecurityPolicy прошло после отзыва разрешения."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'is forbidden: User "system:serviceaccount:pmi-37:editor" cannot patch resource "securitypolicies"'* ]]; then
  echo "ОШИБКА: ожидался запрет PATCH, а не ошибка GET или другая причина."
  exit 1
fi
POLICY_AFTER=$(kubectl get securitypolicy pmi-37 -o jsonpath='{.spec.policies.allowHostNetwork}')
echo "allowHostNetwork до запрещённого PATCH: $POLICY_BEFORE; после: $POLICY_AFTER"
if [ "$POLICY_AFTER" != "$POLICY_BEFORE" ]; then
  echo "ОШИБКА: заблокированное изменение затронуло SecurityPolicy."
  exit 1
fi

echo "Шаг 5. Администратор возвращает исходные значения: API и сами объекты исправны."
kubectl -n pmi-37 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get"]}]}'
kubectl patch securitypolicy pmi-37 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":false}}}'
ROLE_AFTER=$(kubectl -n pmi-37 get role target -o jsonpath='{.rules[0].verbs[*]}')
POLICY_AFTER=$(kubectl get securitypolicy pmi-37 -o jsonpath='{.spec.policies.allowHostNetwork}')
echo "После разрешённого восстановления: Role=$ROLE_AFTER; allowHostNetwork=$POLICY_AFTER"
if [ "$ROLE_AFTER" != get ] || [ "$POLICY_AFTER" != false ]; then
  echo "ОШИБКА: разрешённое восстановление политик не выполнено."
  exit 1
fi
echo "УСПЕХ: после отзыва разрешения изменения обеих политик заблокированы; чтение и разрешённые изменения работают."
