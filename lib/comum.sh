#!/usr/bin/env bash
# Funções compartilhadas pelos scripts: mensagens, auditoria e utilitários.
# Não roda sozinho; cada script faz "source" deste arquivo.

# -e para no primeiro erro, -u trata variável indefinida como erro,
# -o pipefail faz o pipe falhar se qualquer comando falhar, -E leva o trap de ERR às funções.
set -Eeuo pipefail

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_LOG="/var/log/garupa"
LOG_AUDITORIA="$DIR_LOG/auditoria.log"
LOG_EXECUCAO="$DIR_LOG/execucao.log"
ETAPA_ATUAL="(início)"

if [[ -t 1 ]]; then
  COR_AZUL=$'\e[1;34m'; COR_VERDE=$'\e[1;32m'; COR_AMARELO=$'\e[1;33m'
  COR_VERMELHO=$'\e[1;31m'; COR_FIM=$'\e[0m'
else
  COR_AZUL=""; COR_VERDE=""; COR_AMARELO=""; COR_VERMELHO=""; COR_FIM=""
fi

info()  { printf '%s[INFO]%s %s\n' "$COR_VERDE" "$COR_FIM" "$*"; }
aviso() { printf '%s[AVISO]%s %s\n' "$COR_AMARELO" "$COR_FIM" "$*"; }
erro()  { printf '%s[ERRO]%s %s\n' "$COR_VERMELHO" "$COR_FIM" "$*" >&2; }

# Mostra a etapa na tela e registra na auditoria.
etapa() {
  ETAPA_ATUAL="$*"
  printf '\n%s==> %s%s\n' "$COR_AZUL" "$*" "$COR_FIM"
  auditoria ETAPA "$*"
}

# Quem chamou o sudo; se entrou direto como root, o usuário do login.
quem_executou() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    echo "$SUDO_USER"
  else
    logname 2>/dev/null || id -un
  fi
}

# Grava uma linha chave=valor na auditoria e no journal.
# Nunca passe senha, telefone, coordenada ou ficha médica para cá.
auditoria() {
  local evento="$1" detalhe="${2:-}" linha
  linha="$(date --iso-8601=seconds) exec=${EXEC_ID:-?} script=${NOME_SCRIPT:-?} usuario=$(quem_executou) host=$(hostname -s) evento=$evento detalhe=\"$detalhe\""
  echo "$linha" >> "$LOG_AUDITORIA" 2>/dev/null || true
  logger -t garupa-auditoria -- "$linha" 2>/dev/null || true
}

falha_na_linha() {
  local linha="$1" comando="$2"
  erro "Falhou na linha $linha (etapa: $ETAPA_ATUAL): $comando"
  auditoria ERRO "linha=$linha etapa=$ETAPA_ATUAL"
}

finaliza_script() {
  local codigo="$1" duracao status
  duracao=$(( $(date +%s) - INICIO_EPOCH ))
  if [[ "$codigo" -eq 0 ]]; then status="SUCESSO"; else status="FALHA"; fi
  auditoria FIM "status=$status codigo=$codigo duracao=${duracao}s"
  if [[ "$codigo" -eq 0 ]]; then
    printf '\n%s[OK]%s %s terminou em %ss. Auditoria: %s\n' "$COR_VERDE" "$COR_FIM" "$NOME_SCRIPT" "$duracao" "$LOG_AUDITORIA"
  else
    printf '\n%s[FALHA]%s %s parou com código %s. Veja %s\n' "$COR_VERMELHO" "$COR_FIM" "$NOME_SCRIPT" "$codigo" "$LOG_EXECUCAO" >&2
  fi
}

# Primeira chamada de todo script: exige root, prepara os logs e liga a auditoria.
inicia_script() {
  if [[ $EUID -ne 0 ]]; then
    erro "Este script precisa de root. Rode: sudo $0 $*"
    exit 1
  fi
  NOME_SCRIPT="$(basename "$0")"
  EXEC_ID="$(date +%Y%m%d%H%M%S)-$$"
  INICIO_EPOCH="$(date +%s)"

  install -d -m 0755 -o root -g root "$DIR_LOG"
  touch "$LOG_AUDITORIA" "$LOG_EXECUCAO"
  chmod 0640 "$LOG_AUDITORIA" "$LOG_EXECUCAO"

  # Duplica a saída da tela no log de execução.
  exec > >(tee -a "$LOG_EXECUCAO") 2>&1
  printf '\n### %s | %s | exec=%s | usuario=%s\n' \
    "$(date --iso-8601=seconds)" "$NOME_SCRIPT" "$EXEC_ID" "$(quem_executou)"

  # Só reporta falhas do script principal. Dentro de $(...) um código diferente de 0
  # pode ser esperado (ex.: systemctl is-active de um serviço parado) e não interrompe o script.
  trap '[[ $BASH_SUBSHELL -eq 0 ]] && falha_na_linha "$LINENO" "$BASH_COMMAND"' ERR
  trap 'finaliza_script $?' EXIT
  auditoria INICIO "args=$*"
}

carrega_config() {
  local arq="$RAIZ_REPO/config/garupa.conf"
  if [[ ! -f "$arq" ]]; then
    erro "Não encontrei $arq"
    erro "Crie a partir do exemplo: cp config/garupa.conf.example config/garupa.conf"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$arq"
}

# Avisa se não for AlmaLinux 9/10 e guarda a versão principal em VERSAO_SO.
confere_sistema() {
  # shellcheck source=/dev/null
  source /etc/os-release
  VERSAO_SO="${VERSION_ID%%.*}"
  if [[ "${ID:-}" != "almalinux" ]]; then
    aviso "Sistema detectado: ${PRETTY_NAME:-desconhecido}. Os scripts foram feitos para AlmaLinux 9/10."
  fi
  if [[ "$VERSAO_SO" != "9" && "$VERSAO_SO" != "10" ]]; then
    aviso "Versão $VERSION_ID não testada. Continue por sua conta."
  fi
}

# Gera um arquivo a partir de um template, substituindo só as variáveis listadas
# (as do Nginx, como $host, ficam intactas).
# Ex.: renderiza templates/x.conf /etc/x.conf '${VM_HOSTNAME} ${APP_PORTA}'
renderiza() {
  local origem="$1" destino="$2" variaveis="$3" modo="${4:-0644}"
  local tmp
  tmp="$(mktemp)"
  envsubst "$variaveis" < "$origem" > "$tmp"
  install -m "$modo" -o root -g root "$tmp" "$destino"
  rm -f "$tmp"
}

# Grava CHAVE="valor" num .env, substituindo a linha se ela já existir.
env_define() {
  local arquivo="$1" chave="$2" valor="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$arquivo" ]]; then
    grep -v "^${chave}=" "$arquivo" > "$tmp" || true
  fi
  printf '%s="%s"\n' "$chave" "$valor" >> "$tmp"
  cat "$tmp" > "$arquivo"
  rm -f "$tmp"
}

# Lê o valor de CHAVE num .env (vazio se não existir).
env_le() {
  local arquivo="$1" chave="$2"
  [[ -f "$arquivo" ]] || return 0
  grep "^${chave}=" "$arquivo" | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

# Segredo aleatório em hexadecimal: sem caracteres que quebrem SQL ou .env.
gera_segredo() { openssl rand -hex 24; }
