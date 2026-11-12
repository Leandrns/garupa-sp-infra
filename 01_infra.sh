#!/usr/bin/env bash
# Prepara a VM: hostname, hora, rede e DNS, pacotes, firewall, SELinux, usuários de serviço e logs.
# Uso: sudo ./01_infra.sh (pode rodar de novo; só muda o que estiver diferente).
source "$(dirname "$0")/lib/comum.sh"
inicia_script "$@"
carrega_config
confere_sistema

etapa "1/9 Identidade: hostname"
if [[ "$(hostnamectl --static)" != "$VM_HOSTNAME" ]]; then
  hostnamectl set-hostname "$VM_HOSTNAME"
  info "Hostname alterado para $VM_HOSTNAME"
else
  info "Hostname já é $VM_HOSTNAME"
fi

etapa "2/9 Fuso horário e sincronização de hora (NTP)"
# Hora errada estraga a ordem dos logs e a expiração de tokens.
timedatectl set-timezone "$FUSO_HORARIO"
systemctl enable --now chronyd
timedatectl set-ntp true
info "Fuso: $(timedatectl show -p Timezone --value) | NTP sincronizado: $(timedatectl show -p NTPSynchronized --value)"

etapa "3/9 Rede: IP e DNS"
DISPOSITIVO="$(ip -4 route show default | awk '{print $5; exit}')"
if [[ -z "$DISPOSITIVO" ]]; then
  erro "Nenhuma rota padrão encontrada. A VM está sem rede? Confira com: ip a"
  exit 1
fi
CONEXAO="$(nmcli -g GENERAL.CONNECTION device show "$DISPOSITIVO")"
IP_ATUAL="$(ip -4 -o addr show dev "$DISPOSITIVO" | awk '{print $4; exit}' | cut -d/ -f1)"
info "Interface: $DISPOSITIVO | conexão NetworkManager: $CONEXAO | IP atual: $IP_ATUAL"

ANTES="$(nmcli -g ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.ignore-auto-dns connection show "$CONEXAO")"

if [[ "$REDE_MODO" == "estatico" ]]; then
  # Trocar o IP pela própria sessão SSH derrubaria a conexão no meio do script.
  if [[ "$IP_ATUAL" != "$REDE_IP" && -n "${SSH_CONNECTION:-}" ]]; then
    erro "Você pediu IP fixo $REDE_IP, mas a VM está em $IP_ATUAL e você está conectado por SSH."
    erro "Trocar o IP agora derrubaria a sua sessão. Rode este script pelo CONSOLE da VM."
    exit 1
  fi
  nmcli connection modify "$CONEXAO" \
    ipv4.method manual \
    ipv4.addresses "$REDE_IP/$REDE_PREFIXO" \
    ipv4.gateway "$REDE_GATEWAY"
else
  nmcli connection modify "$CONEXAO" ipv4.method auto ipv4.addresses "" ipv4.gateway ""
fi
# Usa os DNS do config e ignora os que vêm do DHCP.
nmcli connection modify "$CONEXAO" ipv4.dns "$REDE_DNS" ipv4.ignore-auto-dns yes

# Só reativa a conexão se algo mudou.
DEPOIS="$(nmcli -g ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.ignore-auto-dns connection show "$CONEXAO")"
if [[ "$ANTES" != "$DEPOIS" ]]; then
  info "Configuração de rede mudou; reaplicando a conexão $CONEXAO"
  nmcli connection up "$CONEXAO" >/dev/null
  sleep 3
else
  info "Rede já estava como configurado; nada a reaplicar"
fi

IP_ATUAL="$(ip -4 -o addr show dev "$DISPOSITIVO" | awk '{print $4; exit}' | cut -d/ -f1)"
info "IP em uso: $IP_ATUAL | DNS: $(nmcli -g IP4.DNS device show "$DISPOSITIVO" | paste -sd' ')"

# Uma única linha do Garupa no /etc/hosts, marcada para poder ser trocada.
sed -i '/# garupa-sp$/d' /etc/hosts
echo "$IP_ATUAL  $VM_HOSTNAME  # garupa-sp" >> /etc/hosts

if getent hosts github.com >/dev/null; then
  info "DNS funcionando (github.com resolvido)"
else
  erro "A VM não resolve nomes. Confira REDE_DNS no config e a rede da VM."
  exit 1
fi

etapa "4/9 Pacotes base (EPEL, ferramentas, atualizações)"
# EPEL traz pacotes extras; o CRB é pré-requisito dele.
dnf -y install epel-release dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install \
  curl git tar unzip vim-enhanced jq bind-utils \
  chrony firewalld logrotate audit \
  policycoreutils-python-utils gettext openssl \
  bash-completion stress-ng
# No AlmaLinux 10 o augenrules e a pasta /etc/audit/rules.d ficam no pacote audit-rules
# (no 9 vêm dentro do audit, e o audit-rules não existe).
if dnf -q info audit-rules >/dev/null 2>&1; then
  dnf -y install audit-rules
fi

if [[ "$ATUALIZAR_SISTEMA" == "sim" ]]; then
  info "Aplicando atualizações de segurança (pode demorar na primeira vez)..."
  dnf -y upgrade --refresh
  if ! dnf needs-restarting -r >/dev/null 2>&1; then
    aviso "Atualizações do kernel ou do systemd pedem REBOOT. Ao final, rode: sudo reboot"
  fi
fi

etapa "5/9 Firewall (firewalld): só SSH, HTTP e HTTPS"
# API (porta interna) e banco (5432) ficam fechados: só o Nginx é exposto.
systemctl enable --now firewalld
ZONA="$(firewall-cmd --get-default-zone)"
for servico in ssh http https; do
  firewall-cmd --permanent --zone="$ZONA" --add-service="$servico" >/dev/null
done
# O Cockpit (porta 9090) vem liberado no AlmaLinux e não é usado.
firewall-cmd --permanent --zone="$ZONA" --remove-service=cockpit >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null
info "Zona $ZONA libera: $(firewall-cmd --zone="$ZONA" --list-services)"

etapa "6/9 SELinux em modo enforcing"
case "$(getenforce)" in
  Enforcing)  info "SELinux já está Enforcing" ;;
  Permissive)
    setenforce 1
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    info "SELinux passou de Permissive para Enforcing" ;;
  Disabled)
    # Ir direto para enforcing pode travar o boot: primeiro permissive e reetiquetagem.
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    touch /.autorelabel
    aviso "SELinux estava desligado. Rode: sudo reboot  e depois este script de novo." ;;
esac

etapa "7/9 Usuários de serviço e pastas"
# Usuários sem senha, sem shell e sem sudo: um para a API, outro para o monitor.
if ! id garupa >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /opt/garupa --no-create-home \
          --shell /sbin/nologin --comment "Garupa SP - API" garupa
  info "Usuário garupa criado"
fi
if ! id garupa-mon >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /var/lib/garupa-mon --no-create-home \
          --shell /sbin/nologin --comment "Garupa SP - monitor" garupa-mon
  info "Usuário garupa-mon criado"
fi
info "garupa: $(id garupa)"
info "garupa-mon: $(id garupa-mon)"

# Código (/opt/garupa) e configuração (/etc/garupa): root escreve, a API só lê.
install -d -m 0750 -o root -g garupa /opt/garupa /opt/garupa/releases
install -d -m 0750 -o root -g garupa /etc/garupa
install -d -m 0755 -o root -g root   /var/log/garupa
for arquivo in monitor.log alertas.log; do
  [[ -f "/var/log/garupa/$arquivo" ]] || install -m 0640 -o garupa-mon -g garupa-mon /dev/null "/var/log/garupa/$arquivo"
done

etapa "8/9 Logs: journal persistente, rotação e auditd"
install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$RAIZ_REPO/templates/journald-garupa.conf" /etc/systemd/journald.conf.d/garupa.conf
systemctl restart systemd-journald

install -m 0644 "$RAIZ_REPO/templates/logrotate-garupa" /etc/logrotate.d/garupa
if logrotate -d /etc/logrotate.d/garupa >/dev/null 2>&1; then
  info "logrotate: regra válida"
else
  aviso "logrotate acusou problema; veja: logrotate -d /etc/logrotate.d/garupa"
fi

systemctl enable --now auditd
install -d -m 0750 /etc/audit/rules.d
install -m 0600 "$RAIZ_REPO/templates/auditd-garupa.rules" /etc/audit/rules.d/garupa.rules
if augenrules --load >/dev/null 2>&1; then
  info "auditd: $(auditctl -l | grep -c 'garupa-') regras do Garupa ativas"
else
  aviso "auditd não carregou as regras; veja: augenrules --check"
fi

etapa "9/9 SSH"
systemctl enable --now sshd
if [[ "$ENDURECER_SSH" == "sim" ]]; then
  install -m 0600 "$RAIZ_REPO/templates/sshd-garupa.conf" /etc/ssh/sshd_config.d/50-garupa.conf
  sshd -t   # valida antes de recarregar
  systemctl reload sshd
  info "SSH endurecido (root só entra por chave)"
else
  info "SSH mantido no padrão (ENDURECER_SSH=nao)"
fi

echo
info "Infraestrutura pronta. Próximo passo: sudo ./02_app.sh"
info "Acesso: ssh <seu-usuario>@$IP_ATUAL"
