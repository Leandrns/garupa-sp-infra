#!/usr/bin/env bash
# Instala o garupa-monitor como serviço systemd, grava os limites em /etc/garupa/monitor.conf
# e dá ao monitor permissão só para reiniciar a API.
# Uso: sudo ./03_monitor.sh (rode de novo depois de mudar um limite no config).
source "$(dirname "$0")/lib/comum.sh"
inicia_script "$@"
carrega_config

if ! id garupa-mon >/dev/null 2>&1; then
  erro "O usuário garupa-mon não existe. Rode antes: sudo ./01_infra.sh"
  exit 1
fi

etapa "1/4 Script do monitor"
install -m 0755 -o root -g root "$RAIZ_REPO/monitor/garupa-monitor.sh" /usr/local/bin/garupa-monitor
bash -n /usr/local/bin/garupa-monitor   # confere a sintaxe
info "Instalado em /usr/local/bin/garupa-monitor"

etapa "2/4 Limites configuráveis (/etc/garupa/monitor.conf)"
# Legível por todos, a menos que tenha a URL do webhook.
MODO_CONF=0644
[[ -n "$ALERTA_WEBHOOK_URL" ]] && MODO_CONF=0640
TMP_CONF="$(mktemp)"
cat > "$TMP_CONF" <<CONF
# Gerado por 03_monitor.sh em $(date --iso-8601=seconds). Relido a cada ciclo.
# Para mudar de vez, edite config/garupa.conf e rode 03_monitor.sh.
INTERVALO=$MONITOR_INTERVALO
CPU_LIMITE=$CPU_LIMITE
MEM_LIMITE=$MEM_LIMITE
DISCO_LIMITE=$DISCO_LIMITE
DISCO_PONTO="/"
SAUDE_URL="http://127.0.0.1:$APP_PORTA$SAUDE_CAMINHO"
SAUDE_FALHAS_PARA_REINICIAR=$SAUDE_FALHAS_PARA_REINICIAR
REPETIR_ALERTA_A_CADA=$REPETIR_ALERTA_A_CADA
SERVICOS="garupa-api postgresql nginx"
ALERTA_WEBHOOK_URL="$ALERTA_WEBHOOK_URL"
CONF
install -m "$MODO_CONF" -o root -g garupa-mon "$TMP_CONF" /etc/garupa/monitor.conf
rm -f "$TMP_CONF"
# /etc/garupa é 0750 root:garupa; a ACL deixa o garupa-mon só atravessar a pasta.
setfacl -m u:garupa-mon:x /etc/garupa
info "CPU ${CPU_LIMITE}% | memória ${MEM_LIMITE}% | disco ${DISCO_LIMITE}% | a cada ${MONITOR_INTERVALO}s"

etapa "3/4 Permissão mínima: reiniciar a API via sudo"
TMP_SUDO="$(mktemp)"
cp "$RAIZ_REPO/templates/sudoers-garupa-monitor" "$TMP_SUDO"
# Valida antes de instalar: um sudoers quebrado tranca o sudo da máquina.
visudo -cf "$TMP_SUDO"
install -m 0440 -o root -g root "$TMP_SUDO" /etc/sudoers.d/garupa-monitor
rm -f "$TMP_SUDO"
info "garupa-mon pode executar só: systemctl restart garupa-api.service"

# Recria os logs do monitor se alguém tiver apagado.
for arquivo in monitor.log alertas.log; do
  [[ -f "/var/log/garupa/$arquivo" ]] || install -m 0640 -o garupa-mon -g garupa-mon /dev/null "/var/log/garupa/$arquivo"
done

etapa "4/4 Serviço systemd garupa-monitor"
install -m 0644 "$RAIZ_REPO/templates/garupa-monitor.service" /etc/systemd/system/garupa-monitor.service
systemctl daemon-reload
systemctl enable garupa-monitor >/dev/null
systemctl restart garupa-monitor
sleep 3
if [[ "$(systemctl is-active garupa-monitor)" != "active" ]]; then
  erro "O monitor não subiu. Veja: journalctl -u garupa-monitor -n 30"
  exit 1
fi
info "garupa-monitor ativo (PID $(systemctl show -p MainPID --value garupa-monitor))"
info "Última linha do monitor: $(tail -n1 /var/log/garupa/monitor.log)"

echo
info "Acompanhe ao vivo:  tail -f /var/log/garupa/monitor.log /var/log/garupa/alertas.log"
info "Próximo passo: sudo ./04_verificar.sh"
