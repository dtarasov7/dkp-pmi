#!/usr/bin/env bash
set -euo pipefail

SERVER_IP=$(kubectl -n pmi-53 get pod server -o jsonpath='{.status.podIP}')
echo "Адрес сервера: $SERVER_IP"
echo "Шаг 1. До политики HTTP-запрос должен проходить."
kubectl -n pmi-53 exec client -c app -- curl --noproxy '*' --fail --show-error --silent --connect-timeout 3 --max-time 3 "http://$SERVER_IP:8080/"
echo "Откройте Hubble, выберите pmi-53 и включите отображение dropped flows."
echo "Шаг 2. Запрещаем входящий трафик к тестовому серверу."
kubectl create -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-server
  namespace: pmi-53
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes: [Ingress]
  ingress: []
YAML
echo "Шаг 3. Повторяем запрос до первого отказа: Cilium применяет правило не мгновенно."
for ATTEMPT in {1..10}; do
  echo "Попытка $ATTEMPT из 10."
  # Не останавливаем скрипт при ожидаемом отказе; сохраняем код команды.
  CURL_STATUS=0
  kubectl -n pmi-53 exec client -c app -- curl --noproxy '*' --fail --show-error --silent --max-time 3 "http://$SERVER_IP:8080/" || CURL_STATUS=$?
  echo "Код запроса: $CURL_STATUS (0 — доступ есть, 28 — тайм-аут)."
  if [ "$CURL_STATUS" -ne 0 ]; then
    break
  fi
  sleep 2
done
if [ "$CURL_STATUS" -ne 28 ]; then
  echo "ОШИБКА: ожидался тайм-аут 28. Другие ошибки не подтверждают сетевой запрет."
  exit 1
fi
echo "Шаг 4. HTTP readinessProbe должна подтверждать, что сервер продолжает отвечать."
kubectl -n pmi-53 wait --for=condition=Ready pod/server --timeout=60s
echo "Сетевой отказ воспроизведён. Для приёмки подтвердите POLICY_DENIED в Hubble по README."
