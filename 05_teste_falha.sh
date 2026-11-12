#!/usr/bin/env bash
# Provoca falhas de propósito e mostra a recuperação ou o alerta.
# Uso: sudo ./05_teste_falha.sh {api|monitor|cpu|memoria|disco|banco|todos}
#   api      kill -9 na API; o systemd sobe de novo
#   monitor  kill -9 no monitor; o systemd sobe de novo
#   cpu      stress-ng na CPU; alerta de CPU
#   memoria  stress-ng na memória; alerta de memória
#   disco    arquivo grande até passar do limite; alerta de disco
#   banco    para o PostgreSQL; /saude responde 503
# A saída fica em /var/log/garupa/execucao.log (serve de evidência).
source "$(dirname "$0")/lib/comum.sh"
inicia_script "$@"
carrega_config

# Apaga o arquivo do teste de disco mesmo se o script for interrompido.
trap 'codigo=$?; rm -f "$ARQ_DISCO"; finaliza_script "$codigo"' EXIT

CENARIO="${1:-}"
URL_SAUDE="http://127.0.0.1:$APP_PORTA$SAUDE_CAMINHO"
ESPERA_ALERTA=$(( MONITOR_INTERVALO * 2 + 5 ))
ARQ_DISCO="/var/tmp/garupa-teste-disco.bin"

uso() {
  echo "Uso: sudo $0 {api|cpu|memoria|disco|banco|monitor|todos}"
  exit 1
}

mostra_alertas() {
  echo "Últimas linhas de /var/log/garupa/alertas.log:"
  tail -n "${1:-5}" /var/log/garupa/alertas.log
}

codigo_saude() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL_SAUDE" || true; }

linhas_alerta() { wc -l < /var/log/garupa/alertas.log; }

# Espera até ESPERA_ALERTA segundos por uma linha nova no alertas.log que contenha o texto.
espera_alerta() {
  local texto="$1" linhas_antes="$2" limite=$(( SECONDS + ESPERA_ALERTA ))
  while (( SECONDS < limite )); do
    if tail -n +"$(( linhas_antes + 1 ))" /var/log/garupa/alertas.log | grep -q "$texto"; then
      info "Alerta registrado: $(tail -n +"$(( linhas_antes + 1 ))" /var/log/garupa/alertas.log | grep "$texto" | tail -n1)"
      return 0
    fi
    sleep 2
  done
  aviso "Nenhum alerta com '$texto' em ${ESPERA_ALERTA}s. Confira os limites em /etc/garupa/monitor.conf"
  return 1
}

teste_api() {
  etapa "Teste: matar a API (kill -9) e ver o systemd reiniciar"
  local pid_antes pid_depois reinicios_antes reinicios_depois
  pid_antes="$(systemctl show -p MainPID --value garupa-api)"
  reinicios_antes="$(systemctl show -p NRestarts --value garupa-api)"
  info "Antes: PID $pid_antes | reinícios até agora: $reinicios_antes | /saude: $(codigo_saude)"
  info "Executando: kill -9 $pid_antes"
  kill -9 "$pid_antes"
  sleep 1
  info "Logo depois: estado $(systemctl is-active garupa-api) | /saude: $(codigo_saude)"
  info "Aguardando o systemd (RestartSec=5)..."
  for _ in $(seq 1 20); do
    [[ "$(codigo_saude)" == "200" ]] && break
    sleep 1
  done
  pid_depois="$(systemctl show -p MainPID --value garupa-api)"
  reinicios_depois="$(systemctl show -p NRestarts --value garupa-api)"
  info "Depois: PID $pid_depois | reinícios: $reinicios_depois | /saude: $(codigo_saude)"
  journalctl -u garupa-api --since "-1min" --no-pager | grep -Ei 'killed|SIGKILL|restart|Started|Main process' | tail -n 5 || true
  if [[ "$pid_depois" != "$pid_antes" && "$(codigo_saude)" == "200" ]]; then
    info "RESULTADO: a API voltou sozinha com outro PID."
  else
    erro "RESULTADO: a API não voltou. Veja: journalctl -u garupa-api -n 50"
    return 1
  fi
}

teste_cpu() {
  etapa "Teste: estressar a CPU por $(( ESPERA_ALERTA + 10 ))s"
  local antes; antes="$(linhas_alerta)"
  info "Executando: stress-ng --cpu 0 --timeout $(( ESPERA_ALERTA + 10 ))s (0 = todos os núcleos)"
  stress-ng --cpu 0 --timeout "$(( ESPERA_ALERTA + 10 ))s" --quiet &
  local pid=$!
  espera_alerta "CPU em" "$antes" || true
  wait "$pid" || true
  info "Carga encerrada; o próximo ciclo do monitor deve registrar NORMALIZADO."
  sleep "$(( MONITOR_INTERVALO + 3 ))"
  mostra_alertas 4
}

teste_memoria() {
  etapa "Teste: ocupar memória por $(( ESPERA_ALERTA + 10 ))s"
  local antes; antes="$(linhas_alerta)"
  # 85% da memória disponível: passa do limite sem acionar o OOM killer.
  info "Executando: stress-ng --vm 1 --vm-bytes 85% --vm-keep"
  stress-ng --vm 1 --vm-bytes 85% --vm-keep --timeout "$(( ESPERA_ALERTA + 10 ))s" --quiet &
  local pid=$!
  espera_alerta "Memória em" "$antes" || true
  wait "$pid" || true
  sleep "$(( MONITOR_INTERVALO + 3 ))"
  mostra_alertas 4
}

teste_disco() {
  etapa "Teste: encher o disco até passar de ${DISCO_LIMITE}%"
  local antes usado livre alvo necessario
  antes="$(linhas_alerta)"
  read -r usado livre < <(df --output=used,avail -B1 / | tail -n1)
  # Mesma conta do df: usado / (usado + livre), sem o espaço reservado ao root.
  alvo=$(( (usado + livre) * (DISCO_LIMITE + 3) / 100 ))
  necessario=$(( alvo - usado ))
  if (( necessario <= 0 )); then
    aviso "O disco já está acima do limite; o alerta deve estar ativo."
  elif (( necessario > livre - 300*1024*1024 )); then
    erro "Precisaria de $(( necessario / 1024 / 1024 )) MB, mas só há $(( livre / 1024 / 1024 )) MB livres. Teste cancelado."
    return 1
  else
    info "Criando $ARQ_DISCO com $(( necessario / 1024 / 1024 )) MB (fallocate)"
    fallocate -l "$necessario" "$ARQ_DISCO"
    df -h /
    espera_alerta "Disco" "$antes" || true
    rm -f "$ARQ_DISCO"
    info "Arquivo removido."
    df -h /
    sleep "$(( MONITOR_INTERVALO + 3 ))"
    mostra_alertas 4
  fi
}

teste_banco() {
  etapa "Teste: parar o banco e ver o /saude falhar"
  local antes; antes="$(linhas_alerta)"
  info "Antes: /saude -> $(codigo_saude)"
  info "Executando: systemctl stop postgresql"
  systemctl stop postgresql
  sleep 2
  info "Com o banco parado:"
  curl -s -i --max-time 5 "$URL_SAUDE" | head -n 1 || true
  curl -s --max-time 5 "$URL_SAUDE" || true
  echo
  espera_alerta "postgresql" "$antes" || true
  info "Executando: systemctl start postgresql"
  systemctl start postgresql
  sleep 3
  info "Depois: /saude -> $(codigo_saude)"
  sleep "$(( MONITOR_INTERVALO + 3 ))"
  mostra_alertas 6
}

teste_monitor() {
  etapa "Teste: matar o próprio monitor e ver o systemd reiniciá-lo"
  local pid_antes pid_depois
  pid_antes="$(systemctl show -p MainPID --value garupa-monitor)"
  info "Antes: PID $pid_antes. Executando: kill -9 $pid_antes"
  kill -9 "$pid_antes"
  sleep 7
  pid_depois="$(systemctl show -p MainPID --value garupa-monitor)"
  info "Depois: estado $(systemctl is-active garupa-monitor) | PID $pid_depois"
  tail -n 2 /var/log/garupa/monitor.log
  if [[ "$pid_depois" != "$pid_antes" && "$pid_depois" != "0" ]]; then
    info "RESULTADO: o monitor voltou sozinho."
  else
    erro "RESULTADO: o monitor não voltou."
    return 1
  fi
}

case "$CENARIO" in
  api)     teste_api ;;
  cpu)     teste_cpu ;;
  memoria) teste_memoria ;;
  disco)   teste_disco ;;
  banco)   teste_banco ;;
  monitor) teste_monitor ;;
  todos)   teste_api; teste_monitor; teste_cpu; teste_memoria; teste_disco; teste_banco ;;
  *)       uso ;;
esac
