#!/usr/bin/env bash
set -euo pipefail

if [ -z "${AUDIT_FILE:-}" ]; then
  echo "ОШИБКА: Укажите путь к выгрузке аудита JSON Lines в AUDIT_FILE"
  exit 1
fi
echo "Проверяем события audit-marker из пространства pmi-56."
# Оставляем завершённые события только для тестового ConfigMap.
EVENTS=$(jq -s '
  [.[]
   | select(.kind == "Event")
   | select(.stage == "ResponseComplete")
   | select(.objectRef.namespace == "pmi-56")
   | select(.objectRef.resource == "configmaps")
   | select(.objectRef.name == "audit-marker")]
' "$AUDIT_FILE")
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
    echo "ОШИБКА: операция отсутствует в выгрузке аудита."
    exit 1
  fi
done
# При impersonation имя проверяемой учётной записи записано в impersonatedUser.
COUNT=$(echo "$EVENTS" | jq '
  [.[]
   | select(.verb == "get")
   | select(.responseStatus.code == 403)
   | select((.impersonatedUser.username // .user.username) == "system:serviceaccount:pmi-56:observer")] | length
')
echo "Запретов для observer: $COUNT"
if [ "$COUNT" -eq 0 ]; then
  echo "ОШИБКА: нет записи ожидаемого отказа."
  exit 1
fi
echo "УСПЕХ: разрешённые действия и отказ зарегистрированы в аудите."
