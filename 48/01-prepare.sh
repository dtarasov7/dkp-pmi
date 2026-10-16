#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем готовность модулей Deckhouse."
if MODULE_PHASE=$(kubectl get module "log-shipper" -o jsonpath='{.status.phase}'); then
  echo "Модуль log-shipper: $MODULE_PHASE"
else
  echo "ОШИБКА: не удалось получить состояние модуля log-shipper. Вывод Kubernetes приведён выше."
  exit 1
fi
if [ "$MODULE_PHASE" != Ready ]; then
  echo "ОШИБКА: модуль log-shipper не готов. Выполните kubectl get module log-shipper -o yaml и устраните указанную там причину."
  exit 1
fi

echo "Проверяем необходимые поля API deckhouse.io/v1alpha1."
for FIELD in clusterloggingconfig.spec.kubernetesPods.namespaceSelector.matchNames clusterloggingconfig.spec.kubernetesPods.labelSelector clusterloggingconfig.spec.destinationRefs clusterlogdestination.spec.socket.address clusterlogdestination.spec.socket.mode clusterlogdestination.spec.socket.encoding.codec; do
  if FIELD_DESCRIPTION=$(kubectl explain "$FIELD" --api-version=deckhouse.io/v1alpha1); then
    echo "$FIELD_DESCRIPTION"
  else
    echo "ОШИБКА: API deckhouse.io/v1alpha1 не предоставляет поле $FIELD или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
    exit 1
  fi
done

echo "Проверяем поддержку формата Syslog схемой установленного сборщика."
CODECS=$(kubectl get crd clusterlogdestinations.deckhouse.io -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].schema.openAPIV3Schema.properties.spec.properties.socket.properties.encoding.properties.codec.enum}')
echo "Форматы в схеме: $CODECS"
if [[ "$CODECS" != *'"Syslog"'* ]]; then
  echo "ОШИБКА: схема v1alpha1 не подтверждает поддержку codec Syslog. Нужен совместимый вариант отправки в syslog."
  exit 1
fi
ETCD_PODS=$(kubectl -n kube-system get pods -l component=etcd -o name)
echo "Источники журналов etcd: $ETCD_PODS"
if [ -z "$ETCD_PODS" ]; then
  echo "ОШИБКА: не найдены Pod etcd с меткой component=etcd; маршрут не будет собирать журналы."
  exit 1
fi

: "${SYSLOG_ADDRESS:?Укажите адрес выделенного syslog-приёмника host:port в SYSLOG_ADDRESS}"
echo "Создаём отдельный маршрут только для журналов Pod etcd."
kubectl create -f - <<YAML
apiVersion: deckhouse.io/v1alpha1
kind: ClusterLogDestination
metadata:
  name: pmi-48-syslog
spec:
  type: Socket
  socket:
    address: "$SYSLOG_ADDRESS"
    mode: TCP
    encoding:
      codec: Syslog
---
apiVersion: deckhouse.io/v1alpha1
kind: ClusterLoggingConfig
metadata:
  name: pmi-48-etcd
spec:
  type: KubernetesPods
  kubernetesPods:
    namespaceSelector:
      matchNames: ["kube-system"]
    labelSelector:
      matchLabels:
        component: etcd
  destinationRefs: ["pmi-48-syslog"]
YAML
echo "Маршрут создан; ожидайте новые штатные сообщения etcd."
