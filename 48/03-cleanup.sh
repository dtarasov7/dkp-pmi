#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только тестовый маршрут, оставляя системные журналы и общий сборщик."
kubectl delete clusterloggingconfig pmi-48-etcd --ignore-not-found
kubectl delete clusterlogdestination pmi-48-syslog --ignore-not-found
