#!/usr/bin/env bash
# Roda 01_infra.sh, 02_app.sh, 03_monitor.sh e 04_verificar.sh em ordem e para no primeiro erro.
# Uso: sudo bash provisionar.sh
set -Eeuo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "Rode como root: sudo $0" >&2
  exit 1
fi

for passo in 01_infra.sh 02_app.sh 03_monitor.sh 04_verificar.sh; do
  echo
  echo "### $passo"
  bash "./$passo"   # "bash" funciona mesmo sem a permissão de execução
done

echo
echo "Provisionamento completo. Auditoria: /var/log/garupa/auditoria.log"
