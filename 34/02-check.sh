#!/usr/bin/env bash
set -euo pipefail

if [ -z "${AUDIT_FILE:-}" ]; then
  AUDIT_FILE=/var/log/kube-audit/audit.log
fi
START_TIME=$(kubectl get namespace pmi-34 -o jsonpath='{.metadata.creationTimestamp}')
if [ -z "$START_TIME" ]; then
  echo "ОШИБКА: время создания тестового namespace не найдено. Сначала выполните 01-prepare.sh."
  exit 1
fi
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
echo "Источник аудита: $AUDIT_FILE"
echo "Проверяем события pmi-34 с момента создания namespace: $START_TIME"

# Читаем журнал напрямую; sudo нужен только при отсутствии прав чтения.
# Сначала отбираем события теста, затем собираем их в массив для подсчёта.
EVENTS=$(
  if [ -r "$AUDIT_FILE" ]; then
    cat "$AUDIT_FILE"
  else
    sudo cat "$AUDIT_FILE"
  fi |
  jq -c --arg start "$START_TIME" --arg end "$END_TIME" '
    select(.kind == "Event")
    | select(.stage == "ResponseComplete")
    | select(.objectRef.namespace == "pmi-34")
    | select(.objectRef.resource == "configmaps")
    | select(.objectRef.name == "audit-marker")
    | select(.requestReceivedTimestamp[0:19] >= $start[0:19])
    | select(.requestReceivedTimestamp[0:19] <= $end)
  ' | jq -s '.'
)
echo "$EVENTS" | jq '.[] | {auditID,requestReceivedTimestamp,user,impersonatedUser,verb,objectRef,responseStatus,annotations}'
for VERB in create get patch delete; do
  COUNT=$(echo "$EVENTS" | jq --arg verb "$VERB" '
    [.[]
     | select(.verb == $verb)
     | select(.responseStatus.code >= 200)
     | select(.responseStatus.code < 300)] | length
  ')
  echo "Успешных событий $VERB: $COUNT"
  if [ "$COUNT" -eq 0 ]; then
    echo "ОШИБКА: операция отсутствует в журнале за время текущего испытания. См. README."
    exit 1
  fi
done
# При impersonation имя проверяемой учётной записи записано в impersonatedUser.
COUNT=$(echo "$EVENTS" | jq '
  [.[]
   | select(.verb == "get")
   | select(.responseStatus.code == 403)
   | select((.impersonatedUser.username // .user.username) == "system:serviceaccount:pmi-34:observer")] | length
')
echo "Запретов для observer: $COUNT"
if [ "$COUNT" -eq 0 ]; then
  echo "ОШИБКА: нет записи ожидаемого отказа."
  exit 1
fi
echo "УСПЕХ: разрешённые действия и отказ зарегистрированы в аудите."
