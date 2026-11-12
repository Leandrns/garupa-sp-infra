#!/usr/bin/env bash
# Confere a infraestrutura inteira e mostra OK ou FALHOU em cada item. Não altera nada.
# Uso: sudo ./04_verificar.sh
source "$(dirname "$0")/lib/comum.sh"
inicia_script "$@"
carrega_config

FALHAS=0
# confere "descrição" comando [args...]
confere() {
  local descricao="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s[OK]%s     %s\n' "$COR_VERDE" "$COR_FIM" "$descricao"
  else
    printf '  %s[FALHOU]%s %s\n' "$COR_VERMELHO" "$COR_FIM" "$descricao"
    FALHAS=$(( FALHAS + 1 ))
  fi
}
http_200() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" == "200" ]]; }
ativo()    { [[ "$(systemctl is-active "$1")" == "active" ]]; }
habilitado() { [[ "$(systemctl is-enabled "$1")" == "enabled" ]]; }

IP="$(hostname -I | awk '{print $1}')"

etapa "Infraestrutura (01_infra.sh)"
confere "hostname é $VM_HOSTNAME"                  test "$(hostnamectl --static)" = "$VM_HOSTNAME"
confere "fuso horário é $FUSO_HORARIO"             test "$(timedatectl show -p Timezone --value)" = "$FUSO_HORARIO"
confere "relógio sincronizado (NTP)"               test "$(timedatectl show -p NTPSynchronized --value)" = "yes"
confere "DNS resolve github.com"                   getent hosts github.com
confere "firewalld ativo"                          ativo firewalld
confere "firewall libera http"                     firewall-cmd --query-service=http
confere "firewall NÃO libera a porta do banco"     bash -c '! firewall-cmd --query-port=5432/tcp'
confere "SELinux em Enforcing"                     test "$(getenforce)" = "Enforcing"
confere "usuário de serviço garupa sem shell"      test "$(getent passwd garupa | cut -d: -f7)" = "/sbin/nologin"
confere "journal persistente"                      test -d /var/log/journal
confere "regra de logrotate válida"                logrotate -d /etc/logrotate.d/garupa
confere "regras do auditd carregadas"              bash -c 'auditctl -l | grep -q garupa-config'

etapa "Aplicação (02_app.sh)"
confere "postgresql ativo e habilitado no boot"    bash -c 'systemctl is-active -q postgresql && systemctl is-enabled -q postgresql'
confere "banco escuta só em localhost"             bash -c '! ss -ltn | grep -Eq "(0\.0\.0\.0|\*|\[::\]):5432 "'
confere "garupa-api ativa"                         ativo garupa-api
confere "garupa-api habilitada no boot"            habilitado garupa-api
confere "garupa-api com Restart=on-failure"        test "$(systemctl show -p Restart --value garupa-api)" = "on-failure"
confere "garupa-api roda como usuário garupa"      test "$(systemctl show -p User --value garupa-api)" = "garupa"
confere "segredos em /etc/garupa/garupa.env (0640)" test "$(stat -c %a /etc/garupa/garupa.env)" = "640"
confere "API responde direto (127.0.0.1:$APP_PORTA)" http_200 "http://127.0.0.1:$APP_PORTA$SAUDE_CAMINHO"
confere "API NÃO está exposta fora da VM"          bash -c "! ss -ltn | grep -Eq '(0\.0\.0\.0|\*|\[::\]):$APP_PORTA '"
confere "nginx ativo"                              ativo nginx
confere "configuração do nginx válida"             nginx -t
confere "API responde pelo Nginx ($IP)"            http_200 "http://$IP$SAUDE_CAMINHO"

etapa "Monitoramento (03_monitor.sh)"
confere "garupa-monitor ativo"                     ativo garupa-monitor
confere "garupa-monitor habilitado no boot"        habilitado garupa-monitor
confere "garupa-monitor com Restart=always"        test "$(systemctl show -p Restart --value garupa-monitor)" = "always"
confere "monitor.log atualizado nos últimos 2 min" bash -c 'test -n "$(find /var/log/garupa/monitor.log -mmin -2)"'

echo
info "Resposta do /saude pelo Nginx:"
curl -s --max-time 5 "http://$IP$SAUDE_CAMINHO" || true
echo
echo
if (( FALHAS == 0 )); then
  info "Tudo certo. De fora da VM: curl http://$IP$SAUDE_CAMINHO"
else
  erro "$FALHAS verificação(ões) falharam. Veja a seção 'Problemas comuns' do guia."
  exit 1
fi
