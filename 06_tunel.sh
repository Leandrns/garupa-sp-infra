#!/usr/bin/env bash
# Opcional: publica a API na internet por um túnel do Cloudflare, para VMs sem IP público.
# A conexão sai da VM, então não precisa abrir porta no roteador.
# O endereço do túnel rápido muda a cada reinício do serviço.
# Uso: sudo ./06_tunel.sh
source "$(dirname "$0")/lib/comum.sh"
inicia_script "$@"
carrega_config

etapa "1/3 Instalar o cloudflared (repositório oficial do Cloudflare)"
if ! rpm -q cloudflared >/dev/null 2>&1; then
  curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo -o /etc/yum.repos.d/cloudflared.repo
  dnf -y install cloudflared
fi
info "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"

etapa "2/3 Serviço systemd garupa-tunel"
install -m 0644 "$RAIZ_REPO/templates/garupa-tunel.service" /etc/systemd/system/garupa-tunel.service
systemctl daemon-reload
systemctl enable garupa-tunel >/dev/null
systemctl restart garupa-tunel

etapa "3/3 Endereço público"
# O cloudflared escreve a URL pública no journal ao conectar.
URL=""
for _ in $(seq 1 30); do
  URL="$(journalctl -u garupa-tunel --since '-2min' --no-pager 2>/dev/null \
         | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -n1 || true)"
  [[ -n "$URL" ]] && break
  sleep 2
done
if [[ -z "$URL" ]]; then
  erro "Não encontrei o endereço. Veja: journalctl -u garupa-tunel -n 50"
  exit 1
fi
auditoria TUNEL "endereco_publico=$URL"
info "API pública: $URL$SAUDE_CAMINHO"
info "Teste de qualquer lugar: curl $URL$SAUDE_CAMINHO"
info "Passe este endereço para quem faz o app e o Wokwi."
