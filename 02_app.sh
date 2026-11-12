#!/usr/bin/env bash
# Instala .NET, PostgreSQL e Nginx, cria o banco e os segredos, publica a API como serviço systemd
# e põe o Nginx na frente.
# Uso: sudo ./02_app.sh (rodar de novo publica o último commit da API).
source "$(dirname "$0")/lib/comum.sh"
inicia_script "$@"
carrega_config
confere_sistema

ARQ_ENV="/etc/garupa/garupa.env"
ARQ_SENHA_DB="/etc/garupa/.db_senha"
DIR_SRC="/opt/garupa/src"
DIR_FERRAMENTAS="/opt/garupa/ferramentas"
LINK_APP="/opt/garupa/app"
PG_DADOS="/var/lib/pgsql/data"

if ! id garupa >/dev/null 2>&1; then
  erro "O usuário garupa não existe. Rode antes: sudo ./01_infra.sh"
  exit 1
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

etapa "1/8 Dependências: .NET $DOTNET_VERSAO, PostgreSQL e Nginx"
# No AlmaLinux 9 a versão do PostgreSQL é escolhida por módulo, antes de instalar.
if [[ "$VERSAO_SO" == "9" ]] && ! rpm -q postgresql-server >/dev/null 2>&1; then
  dnf -y module reset postgresql
  dnf -y module enable "postgresql:$PG_VERSAO"
fi
dnf -y install "dotnet-sdk-$DOTNET_VERSAO" postgresql-server postgresql nginx git
info ".NET: $(dotnet --version) | PostgreSQL: $(rpm -q --qf '%{VERSION}' postgresql-server) | Nginx: $(rpm -q --qf '%{VERSION}' nginx)"
export DOTNET_ROOT
DOTNET_ROOT="$(dirname "$(readlink -f "$(command -v dotnet)")")"

etapa "2/8 Banco de dados PostgreSQL"
if [[ ! -f "$PG_DADOS/PG_VERSION" ]]; then
  postgresql-setup --initdb
  info "Cluster do PostgreSQL criado em $PG_DADOS"
fi

# Regra com senha, só para o nosso banco e só a partir da VM. Vai no topo do
# pg_hba.conf porque vale a primeira regra que casar (o padrão "ident" não serve à API).
HBA="$PG_DADOS/pg_hba.conf"
TMP_HBA="$(mktemp)"
{
  echo "host    $DB_NOME    $DB_USUARIO    127.0.0.1/32    scram-sha-256    # garupa-sp"
  echo "host    $DB_NOME    $DB_USUARIO    ::1/128         scram-sha-256    # garupa-sp"
  grep -v '# garupa-sp$' "$HBA"
} > "$TMP_HBA"
cat "$TMP_HBA" > "$HBA"   # "cat >" mantém dono, permissões e contexto SELinux
rm -f "$TMP_HBA"

systemctl enable --now postgresql
systemctl reload postgresql
info "PostgreSQL: $(systemctl is-active postgresql) | escuta só em: $(runuser -u postgres -- psql -tAc 'SHOW listen_addresses' 2>/dev/null)"

# Senha gerada na primeira vez e reaproveitada nas seguintes.
if [[ -s "$ARQ_SENHA_DB" ]]; then
  DB_SENHA="$(cat "$ARQ_SENHA_DB")"
  info "Senha do banco reaproveitada de $ARQ_SENHA_DB"
else
  DB_SENHA="$(gera_segredo)"
  install -m 0600 -o root -g root /dev/null "$ARQ_SENHA_DB"
  printf '%s' "$DB_SENHA" > "$ARQ_SENHA_DB"
  info "Senha do banco gerada e guardada em $ARQ_SENHA_DB (só root lê)"
fi

# Cria usuário e banco se não existirem. A senha vai pelo heredoc, não pela
# linha de comando, para não aparecer no "ps".
(cd /tmp && runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q) <<SQL
\set usuario '$DB_USUARIO'
\set banco '$DB_NOME'
\set senha '$DB_SENHA'
SELECT format('CREATE ROLE %I LOGIN', :'usuario')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'usuario') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'usuario', :'senha') \gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L TEMPLATE template0', :'banco', :'usuario', 'UTF8')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'banco') \gexec
SQL

if PGPASSWORD="$DB_SENHA" psql -h 127.0.0.1 -U "$DB_USUARIO" -d "$DB_NOME" -tAc 'SELECT 1' >/dev/null; then
  info "Usuário $DB_USUARIO conecta no banco $DB_NOME com senha"
else
  erro "O usuário $DB_USUARIO não conseguiu conectar. Veja $HBA"
  exit 1
fi

etapa "3/8 Variáveis de ambiente e segredos (fora do código)"
# 0640 root:garupa: só root e a API leem.
[[ -f "$ARQ_ENV" ]] || install -m 0640 -o root -g garupa /dev/null "$ARQ_ENV"
CONEXAO="Host=127.0.0.1;Port=5432;Database=$DB_NOME;Username=$DB_USUARIO;Password=$DB_SENHA"
env_define "$ARQ_ENV" ASPNETCORE_ENVIRONMENT "Production"
env_define "$ARQ_ENV" ASPNETCORE_URLS "http://127.0.0.1:$APP_PORTA"
# Faz a API aceitar os cabeçalhos X-Forwarded-* do Nginx.
env_define "$ARQ_ENV" ASPNETCORE_FORWARDEDHEADERS_ENABLED "true"
env_define "$ARQ_ENV" "$APP_CHAVE_CONEXAO" "$CONEXAO"
for segredo in $APP_SEGREDOS_GERADOS; do
  if [[ -z "$(env_le "$ARQ_ENV" "$segredo")" ]]; then
    env_define "$ARQ_ENV" "$segredo" "$(gera_segredo)"
    info "Segredo $segredo gerado"
  fi
done
chown root:garupa "$ARQ_ENV"
chmod 0640 "$ARQ_ENV"
info "Variáveis em $ARQ_ENV: $(cut -d= -f1 "$ARQ_ENV" | paste -sd' ')"   # só os nomes

etapa "4/8 Código e publicação (dotnet publish)"
EXTRA_PUBLISH=()
if [[ -z "$APP_REPO_URL" ]]; then
  MODO="ensaio"
  CSPROJ="$RAIZ_REPO/api-ensaio/Garupa.Ensaio.csproj"
  COMMIT="ensaio"
  EXTRA_PUBLISH=("-p:TargetFramework=net$DOTNET_VERSAO")
  aviso "APP_REPO_URL vazio: publicando a API de ensaio (só /api/v1/saude)"
else
  MODO="repositorio"
  if [[ -d "$DIR_SRC/.git" ]]; then
    git -C "$DIR_SRC" remote set-url origin "$APP_REPO_URL"
    git -C "$DIR_SRC" fetch --prune origin
    git -C "$DIR_SRC" checkout -q "$APP_BRANCH"
    git -C "$DIR_SRC" reset -q --hard "origin/$APP_BRANCH"
  else
    git clone --branch "$APP_BRANCH" "$APP_REPO_URL" "$DIR_SRC"
  fi
  chown -R root:garupa "$DIR_SRC"
  chmod -R u=rwX,g=rX,o= "$DIR_SRC"
  CSPROJ="$DIR_SRC/$APP_CSPROJ"
  COMMIT="$(git -C "$DIR_SRC" rev-parse --short HEAD)"
  info "Código em $DIR_SRC, commit $COMMIT ($(git -C "$DIR_SRC" log -1 --format=%s))"
fi

# Uma pasta por publicação; o link /opt/garupa/app aponta para a ativa (permite voltar versão).
RELEASE="/opt/garupa/releases/$(date +%Y%m%d-%H%M%S)-$COMMIT"
dotnet publish "$CSPROJ" -c Release -o "$RELEASE" "${EXTRA_PUBLISH[@]}"

# O .dll de entrada é o que tem um .runtimeconfig.json ao lado.
shopt -s nullglob
CONFIGS=("$RELEASE"/*.runtimeconfig.json)
shopt -u nullglob
if [[ ${#CONFIGS[@]} -ne 1 ]]; then
  erro "Esperava 1 arquivo .runtimeconfig.json em $RELEASE e achei ${#CONFIGS[@]}. Confira APP_CSPROJ."
  exit 1
fi
APP_DLL="$(basename "${CONFIGS[0]}" .runtimeconfig.json).dll"
info "Publicado em $RELEASE (ponto de entrada: $APP_DLL)"

etapa "5/8 Migrações do banco (EF Core)"
if [[ "$MODO" == "repositorio" && -n "$APP_EF_PROJETO" ]]; then
  # O bundle aplica só as migrações pendentes; com o banco em dia, não faz nada.
  if [[ -x "$DIR_FERRAMENTAS/dotnet-ef" ]]; then
    dotnet tool update --tool-path "$DIR_FERRAMENTAS" dotnet-ef --version "$DOTNET_VERSAO.*"
  else
    dotnet tool install --tool-path "$DIR_FERRAMENTAS" dotnet-ef --version "$DOTNET_VERSAO.*"
  fi
  "$DIR_FERRAMENTAS/dotnet-ef" migrations bundle \
    --project "$DIR_SRC/$APP_EF_PROJETO" \
    --startup-project "$CSPROJ" \
    --configuration Release \
    --output "$RELEASE/efbundle" --force
  "$RELEASE/efbundle" --connection "$CONEXAO"
  info "Migrações aplicadas"
else
  info "Sem migrações nesta execução (modo $MODO)"
fi
chown -R root:garupa "$RELEASE"
chmod -R u=rwX,g=rX,o= "$RELEASE"

etapa "6/8 Serviço systemd garupa-api"
ANTERIOR="$(readlink -f "$LINK_APP" 2>/dev/null || true)"
ln -sfn "$RELEASE" "$LINK_APP"
export APP_DLL
renderiza "$RAIZ_REPO/templates/garupa-api.service" /etc/systemd/system/garupa-api.service '${APP_DLL}'
systemctl daemon-reload
systemctl enable garupa-api >/dev/null
systemctl reset-failed garupa-api 2>/dev/null || true
systemctl restart garupa-api

# Espera o /saude responder 200; se não responder, volta para a versão anterior.
URL_LOCAL="http://127.0.0.1:$APP_PORTA$SAUDE_CAMINHO"
CODIGO="000"
for _ in $(seq 1 30); do
  CODIGO="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL_LOCAL" || true)"
  [[ "$CODIGO" == "200" ]] && break
  sleep 2
done
if [[ "$CODIGO" != "200" ]]; then
  erro "A API não respondeu 200 em $URL_LOCAL (último código: $CODIGO). Últimas linhas do log:"
  journalctl -u garupa-api -n 30 --no-pager || true
  if [[ -n "$ANTERIOR" && -d "$ANTERIOR" && "$ANTERIOR" != "$RELEASE" ]]; then
    aviso "Voltando para a versão anterior: $ANTERIOR"
    ln -sfn "$ANTERIOR" "$LINK_APP"
    systemctl restart garupa-api || true
  fi
  exit 1
fi
info "garupa-api ativa e respondendo 200 em $URL_LOCAL"

if [[ "$MODO" == "repositorio" && -n "$APP_CSV_RISCO" ]]; then
  info "Carregando a tabela de risco: $APP_CSV_RISCO"
  # Roda como o usuário garupa, com as mesmas variáveis do serviço.
  (
    set -a
    # shellcheck source=/dev/null
    source "$ARQ_ENV"
    set +a
    cd "$LINK_APP"
    runuser -u garupa -m -- env HOME=/tmp ASPNETCORE_URLS="http://127.0.0.1:0" \
      dotnet "$APP_DLL" carregar-risco "$DIR_SRC/$APP_CSV_RISCO"
  )
fi

etapa "7/8 Nginx como proxy reverso + SELinux"
# Sem este booleano, o SELinux impede o Nginx de conectar na API (502 Bad Gateway).
if [[ "$(getsebool httpd_can_network_connect | awk '{print $3}')" != "on" ]]; then
  setsebool -P httpd_can_network_connect 1
  info "SELinux: httpd_can_network_connect ligado"
fi
export VM_HOSTNAME APP_PORTA
renderiza "$RAIZ_REPO/templates/nginx-garupa.conf" /etc/nginx/conf.d/garupa.conf '${VM_HOSTNAME} ${APP_PORTA}'
nginx -t
systemctl enable --now nginx
systemctl reload nginx

URL_NGINX="http://127.0.0.1$SAUDE_CAMINHO"
CODIGO="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL_NGINX" || true)"
if [[ "$CODIGO" != "200" ]]; then
  erro "Pelo Nginx a API respondeu $CODIGO. Veja /var/log/nginx/garupa-erro.log"
  exit 1
fi
info "Nginx repassando para a API: $URL_NGINX -> 200"

etapa "8/8 Limpeza de versões antigas"
# Mantém as 3 publicações mais recentes; a ativa é a mais nova.
mapfile -t ANTIGAS < <(ls -1dt /opt/garupa/releases/*/ 2>/dev/null | tail -n +4)
for pasta in "${ANTIGAS[@]}"; do
  rm -rf -- "$pasta"
  info "Removida: $pasta"
done

IP="$(hostname -I | awk '{print $1}')"
echo
info "Aplicação no ar. Teste de outra máquina: curl http://$IP$SAUDE_CAMINHO"
info "Próximo passo: sudo ./03_monitor.sh"
