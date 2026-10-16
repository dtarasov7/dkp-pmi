#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем резервную копию стороннего решения."
velero backup describe pmi-58 --details
PHASE=$(kubectl -n velero get backup pmi-58 -o jsonpath='{.status.phase}')
echo "Состояние копии: $PHASE"
if [ "$PHASE" != Completed ]; then
  echo "ОШИБКА: резервная копия не завершена без ошибок."
  exit 1
fi
echo "Восстанавливаем в отдельный namespace, сохраняя исходное окружение."
kubectl create namespace pmi-58-restored
velero restore create pmi-58 --from-backup pmi-58 --namespace-mappings pmi-58:pmi-58-restored --wait
PHASE=$(kubectl -n velero get restore pmi-58 -o jsonpath='{.status.phase}')
echo "Состояние восстановления: $PHASE"
if [ "$PHASE" != Completed ]; then
  echo "ОШИБКА: восстановление не завершено без ошибок."
  exit 1
fi
VALUE=$(kubectl -n pmi-58-restored get configmap marker -o jsonpath='{.data.value}')
echo "Восстановленное значение: $VALUE"
if [ "$VALUE" != pmi-58-backup ]; then
  echo "ОШИБКА: восстановленные данные неверны."
  exit 1
fi
echo "УСПЕХ: копирование и восстановление объекта Velero проверено. Встроенный backup etcd проверяется отдельно по README."
