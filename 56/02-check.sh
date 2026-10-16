#!/usr/bin/env bash
set -euo pipefail

: "${AUDIT_FILE:?Укажите путь к выгрузке аудита JSON Lines в AUDIT_FILE}"
echo "Проверяем события audit-marker из пространства pmi-56."
EVENTS=$(jq -sc '[.[] | select(.kind == "Event" and .stage == "ResponseComplete" and .objectRef.namespace == "pmi-56" and .objectRef.resource == "configmaps" and .objectRef.name == "audit-marker")]' "$AUDIT_FILE")
echo "$EVENTS" | jq '.[] | {auditID,requestReceivedTimestamp,user,impersonatedUser,verb,objectRef,responseStatus,annotations}'
for VERB in create get patch delete; do
  COUNT=$(echo "$EVENTS" | jq --arg verb "$VERB" '[.[] | select(.verb == $verb and .responseStatus.code >= 200 and .responseStatus.code < 300)] | length')
  echo "Успешных событий $VERB: $COUNT"
  if [ "$COUNT" -eq 0 ]; then
    echo "ОШИБКА: операция отсутствует в выгрузке аудита."
    exit 1
  fi
done
COUNT=$(echo "$EVENTS" | jq '[.[] | select(.verb == "get" and .responseStatus.code == 403 and (.impersonatedUser.username // .user.username) == "system:serviceaccount:pmi-56:observer")] | length')
echo "Запретов для observer: $COUNT"
if [ "$COUNT" -eq 0 ]; then
  echo "ОШИБКА: нет записи ожидаемого отказа."
  exit 1
fi
echo "УСПЕХ: разрешённые действия и отказ зарегистрированы в аудите."
