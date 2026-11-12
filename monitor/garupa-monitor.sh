#!/usr/bin/env bash
# garupa-monitor: mede CPU, memória e disco, confere os serviços e o /saude da API, e grava
# métricas em monitor.log e alertas em alertas.log.
# Instalado em /usr/local/bin pelo 03_monitor.sh; roda como garupa-mon via systemd.
# Relê /etc/garupa/monitor.conf a cada ciclo. Os logs não têm dado pessoal.

# Sem "set -e": uma falha pontual (ex.: curl sem resposta) não pode derrubar o monitor.
set -uo pipefail

CONF="/etc/garupa/monitor.conf"
LOG_MONITOR="/var/log/garupa/monitor.log"
LOG_ALERTAS="/var/log/garupa/alertas.log"

declare -A EM_ALERTA=()     # condição -> 1 enquanto o alerta estiver ativo
declare -A CICLOS_ALERTA=() # condição -> ciclos desde que o alerta começou
FALHAS_SAUDE=0
CPU_TOTAL_ANT=0
CPU_OCIOSO_ANT=0

carrega_conf() {
  # Padrões, caso o arquivo não exista ou falte alguma chave.
  INTERVALO=15
  CPU_LIMITE=80
  MEM_LIMITE=80
  DISCO_LIMITE=85
  DISCO_PONTO="/"
  SAUDE_URL="http://127.0.0.1:5000/api/v1/saude"
  SAUDE_FALHAS_PARA_REINICIAR=3
  REPETIR_ALERTA_A_CADA=20
  SERVICOS="garupa-api postgresql nginx"
  ALERTA_WEBHOOK_URL=""
  # shellcheck source=/dev/null
  [[ -r "$CONF" ]] && source "$CONF"
}

agora() { date --iso-8601=seconds; }

# Escreve no arquivo; se não conseguir, manda para o journal.
grava() {
  local arquivo="$1"; shift
  echo "$*" >> "$arquivo" 2>/dev/null || echo "$*" >&2
}

# Registra o alerta no arquivo, no journal e no webhook (se houver).
alerta() {
  local nivel="$1" mensagem="$2" prioridade="warning"
  [[ "$nivel" == "NORMALIZADO" ]] && prioridade="notice"
  grava "$LOG_ALERTAS" "$(agora) nivel=$nivel host=$(hostname -s) mensagem=\"$mensagem\""
  logger -t garupa-alerta -p "user.$prioridade" -- "$nivel: $mensagem" 2>/dev/null || true
  if [[ -n "$ALERTA_WEBHOOK_URL" ]]; then
    curl -s -m 5 -H 'Content-Type: application/json' \
      -d "{\"content\":\"[Garupa SP] $nivel: $mensagem\"}" \
      "$ALERTA_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

# ALERTA quando a condição começa, repete a cada REPETIR_ALERTA_A_CADA ciclos
# enquanto durar e NORMALIZADO quando acaba. Evita repetir a mesma linha todo ciclo.
condicao() {
  local chave="$1" ativa="$2" mensagem="$3"
  if [[ "$ativa" == "1" ]]; then
    if [[ -z "${EM_ALERTA[$chave]:-}" ]]; then
      EM_ALERTA[$chave]=1
      CICLOS_ALERTA[$chave]=0
      alerta "ALERTA" "$mensagem"
    else
      local ciclos=$(( ${CICLOS_ALERTA[$chave]:-0} + 1 ))
      CICLOS_ALERTA[$chave]=$ciclos
      if (( ciclos % REPETIR_ALERTA_A_CADA == 0 )); then
        alerta "AINDA_EM_ALERTA" "$mensagem"
      fi
    fi
  elif [[ -n "${EM_ALERTA[$chave]:-}" ]]; then
    unset "EM_ALERTA[$chave]" "CICLOS_ALERTA[$chave]"
    alerta "NORMALIZADO" "$mensagem"
  fi
}

# Uso da CPU entre a leitura anterior de /proc/stat e a atual.
# Grava em CPU_USO (global): chamada com $(...), a função perderia a leitura anterior.
mede_cpu() {
  local _ usr nic sys idle iow irq sirq steal total ocioso dt dio
  read -r _ usr nic sys idle iow irq sirq steal _ < /proc/stat
  total=$(( usr + nic + sys + idle + iow + irq + sirq + steal ))
  ocioso=$(( idle + iow ))
  dt=$(( total - CPU_TOTAL_ANT ))
  dio=$(( ocioso - CPU_OCIOSO_ANT ))
  CPU_TOTAL_ANT=$total
  CPU_OCIOSO_ANT=$ocioso
  if (( dt > 0 )); then
    CPU_USO=$(( (100 * (dt - dio)) / dt ))
  else
    CPU_USO=0
  fi
}

# Usa MemAvailable, não MemFree: o cache que o Linux libera quando precisa não conta como uso.
mede_memoria() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo
}

mede_disco() {
  df --output=pcent "$DISCO_PONTO" 2>/dev/null | tail -n1 | tr -dc '0-9'
}

# Processo morto: o systemd reinicia (Restart=on-failure).
# Vivo e sem resposta por N ciclos: o monitor reinicia.
# Resposta 503 (banco fora): só alerta, reiniciar a API não resolve.
# Parado com systemctl stop: só alerta, respeita a parada manual.
checa_saude() {
  local codigo estado
  codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$SAUDE_URL" 2>/dev/null)"
  [[ -z "$codigo" ]] && codigo="000"
  estado="$(systemctl is-active garupa-api 2>/dev/null)"
  SAUDE_CODIGO="$codigo"

  if [[ "$codigo" == "200" ]]; then
    FALHAS_SAUDE=0
    condicao "api_sem_resposta" 0 "API voltou a responder no /saude"
    condicao "api_dependencia" 0 "API voltou a responder 200 no /saude"
    return
  fi

  if [[ "$codigo" != "000" ]]; then
    FALHAS_SAUDE=0
    condicao "api_dependencia" 1 "API respondeu HTTP $codigo no /saude (verifique o banco)"
    return
  fi

  FALHAS_SAUDE=$(( FALHAS_SAUDE + 1 ))
  condicao "api_sem_resposta" 1 "API sem resposta no /saude (estado systemd: $estado)"
  if [[ "$estado" == "active" ]] && (( FALHAS_SAUDE >= SAUDE_FALHAS_PARA_REINICIAR )); then
    if sudo -n /usr/bin/systemctl restart garupa-api.service 2>/dev/null; then
      alerta "ACAO" "API ativa mas sem resposta por $FALHAS_SAUDE ciclos: reiniciada pelo monitor"
    else
      alerta "ACAO_FALHOU" "Tentativa de reiniciar a API falhou (confira /etc/sudoers.d/garupa-monitor)"
    fi
    FALHAS_SAUDE=0
  fi
}

ciclo() {
  local cpu mem disco servicos_ok="sim" s estado
  mede_cpu
  cpu="$CPU_USO"
  mem="$(mede_memoria)"
  disco="$(mede_disco)"
  [[ -z "$disco" ]] && disco=0

  condicao "cpu"   "$(( cpu   >= CPU_LIMITE   ? 1 : 0 ))" "CPU em ${cpu}% (limite ${CPU_LIMITE}%)"
  condicao "mem"   "$(( mem   >= MEM_LIMITE   ? 1 : 0 ))" "Memória em ${mem}% (limite ${MEM_LIMITE}%)"
  condicao "disco" "$(( disco >= DISCO_LIMITE ? 1 : 0 ))" "Disco $DISCO_PONTO em ${disco}% (limite ${DISCO_LIMITE}%)"

  for s in $SERVICOS; do
    estado="$(systemctl is-active "$s" 2>/dev/null)"
    if [[ "$estado" != "active" ]]; then
      servicos_ok="nao"
      condicao "servico_${s//-/_}" 1 "Serviço $s está $estado"
    else
      condicao "servico_${s//-/_}" 0 "Serviço $s ativo de novo"
    fi
  done

  checa_saude

  grava "$LOG_MONITOR" "$(agora) cpu=${cpu}% mem=${mem}% disco=${disco}% api_http=$SAUDE_CODIGO servicos_ok=$servicos_ok alertas_ativos=${#EM_ALERTA[@]}"
}

encerra() {
  grava "$LOG_MONITOR" "$(agora) monitor encerrado (sinal recebido)"
  exit 0
}
trap encerra TERM INT

carrega_conf
grava "$LOG_MONITOR" "$(agora) monitor iniciado (pid $$, intervalo ${INTERVALO}s, limites cpu=${CPU_LIMITE}% mem=${MEM_LIMITE}% disco=${DISCO_LIMITE}%)"
CPU_USO=0
SAUDE_CODIGO="000"
mede_cpu   # primeira leitura, base para o primeiro ciclo
sleep 1

while true; do
  carrega_conf
  ciclo
  # sleep em segundo plano + wait: o "systemctl stop" é atendido na hora.
  sleep "$INTERVALO" &
  wait $!
done
