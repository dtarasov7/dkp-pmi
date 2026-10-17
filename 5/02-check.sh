#!/usr/bin/env bash
set -euo pipefail

if [ -z "${EXPECTED_MARKER:-}" ]; then
  echo "ОШИБКА: Укажите ожидаемый несекретный тестовый маркер в EXPECTED_MARKER"
  exit 1
fi
echo "Читаем только искусственный маркер, не рабочие секреты."
VALUE=$(kubectl -n pmi-5 exec reader -c app -- cat /mnt/external/marker)
echo "Маркер из CSI-тома: $VALUE"
if [ "$VALUE" != "$EXPECTED_MARKER" ]; then
  echo "ОШИБКА: значение не соответствует внешнему хранилищу."
  exit 1
fi
kubectl -n pmi-5 get secretsstoreimport external-secret
kubectl -n pmi-5 get pod reader
echo "УСПЕХ: приложение прочитало ожидаемое значение из внешнего хранилища."
