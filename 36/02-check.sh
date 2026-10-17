#!/usr/bin/env bash
set -euo pipefail

echo "Шаг 1. Observer может читать обе политики, но не имеет права их изменять."
kubectl --as=system:serviceaccount:pmi-36:observer -n pmi-36 get role target
kubectl --as=system:serviceaccount:pmi-36:observer get securitypolicy pmi-36

echo "Шаг 2. Выполняем две попытки изменения от observer. Ожидаем отказ именно на PATCH."
if RESULT=$(kubectl --as=system:serviceaccount:pmi-36:observer -n pmi-36 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list"]}]}' 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: observer получил право изменять Role."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'is forbidden: User "system:serviceaccount:pmi-36:observer" cannot patch resource "roles"'* ]]; then
  echo "ОШИБКА: получен другой отказ; запрет PATCH не подтверждён."
  exit 1
fi
if RESULT=$(kubectl --as=system:serviceaccount:pmi-36:observer patch securitypolicy pmi-36 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":true}}}' 2>&1); then
  echo "$RESULT"
  echo "ОШИБКА: observer получил право изменять SecurityPolicy."
  exit 1
fi
echo "$RESULT"
if [[ "$RESULT" != *'is forbidden: User "system:serviceaccount:pmi-36:observer" cannot patch resource "securitypolicies"'* ]]; then
  echo "ОШИБКА: получен другой отказ; запрет PATCH не подтверждён."
  exit 1
fi

echo "Шаг 3. Editor выполняет те же изменения с разрешённой учётной записью."
kubectl --as=system:serviceaccount:pmi-36:editor -n pmi-36 patch role target --type=merge -p '{"rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list"]}]}'
kubectl --as=system:serviceaccount:pmi-36:editor patch securitypolicy pmi-36 --type=merge -p '{"spec":{"policies":{"allowHostNetwork":true}}}'

echo "Шаг 4. Проверяем регистрацию инициатора и решения авторизации в локальном аудите."
if [ -z "${AUDIT_FILE:-}" ]; then
  AUDIT_FILE=/var/log/kube-audit/audit.log
fi
START_TIME=$(kubectl get namespace pmi-36 -o jsonpath='{.metadata.creationTimestamp}')
if [ -z "$START_TIME" ]; then
  echo "ОШИБКА: не найдено время создания тестового namespace."
  exit 1
fi
EVENTS=$(
  if [ -r "$AUDIT_FILE" ]; then
    cat "$AUDIT_FILE"
  else
    sudo cat "$AUDIT_FILE"
  fi |
  jq -c --arg start "$START_TIME" '
    select(.kind == "Event" and .stage == "ResponseComplete")
    | select(.verb == "patch")
    | select(.requestReceivedTimestamp[0:19] >= $start[0:19])
    | select((.objectRef.apiGroup == "rbac.authorization.k8s.io" and .objectRef.resource == "roles" and .objectRef.namespace == "pmi-36" and .objectRef.name == "target")
          or (.objectRef.apiGroup == "deckhouse.io" and .objectRef.resource == "securitypolicies" and .objectRef.name == "pmi-36"))
  ' | jq -s '.'
)
echo "$EVENTS" | jq '.[] | {auditID,requestReceivedTimestamp,user,impersonatedUser,verb,objectRef,responseStatus,annotations}'

# Для каждого вида политики нужны две записи: отказ observer и разрешение editor.
while read -r RESOURCE ACCOUNT CODE DECISION; do
  COUNT=$(echo "$EVENTS" | jq --arg resource "$RESOURCE" --arg account "system:serviceaccount:pmi-36:$ACCOUNT" --argjson code "$CODE" --arg decision "$DECISION" '
    [.[]
     | select(.objectRef.resource == $resource)
     | select((.impersonatedUser.username // .user.username) == $account)
     | select(.responseStatus.code == $code)
     | select(.annotations["authorization.k8s.io/decision"] == $decision)] | length
  ')
  echo "$RESOURCE: $ACCOUNT, код $CODE, решение $DECISION — найдено записей: $COUNT"
  if [ "$COUNT" -eq 0 ]; then
    echo "ОШИБКА: нужная запись контроля отсутствует. Проверьте политику аудита и запись журнала."
    exit 1
  fi
done <<'EXPECTED'
roles            observer 403 forbid
roles            editor   200 allow
securitypolicies observer 403 forbid
securitypolicies editor   200 allow
EXPECTED
echo "УСПЕХ: контроль изменений обеих политик фиксирует инициатора, отказ и разрешение в аудите."
