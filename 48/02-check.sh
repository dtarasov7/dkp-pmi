#!/usr/bin/env bash
set -euo pipefail

echo "Показываем источник и маршрут журналов etcd."
kubectl -n kube-system get pods -l component=etcd -o wide
PODS=$(kubectl -n kube-system get pods -l component=etcd -o name)
echo "Источники: $PODS"
if [ -z "$PODS" ]; then
  echo "ОШИБКА: источник etcd не найден по селектору."
  exit 1
fi
for POD in $PODS; do
  echo "Штатные сообщения $POD за последний час:"
  kubectl -n kube-system logs "$POD" -c etcd --since=1h --tail=20 --timestamps
done
kubectl get clusterloggingconfig pmi-48-etcd -o yaml
kubectl get clusterlogdestination pmi-48-syslog -o yaml
echo "На удалённом syslog сопоставьте новые сообщения по времени, имени Pod и тексту."
echo "До подтверждения получателя доставка не считается проверенной."
