#!/usr/bin/env bash
# queue.sh - Levanta N instancias Chromium dockerizadas, cada una detras de
# PIA VPN (gluetun) con servidor random de la lista viva de PIA y user agent legitimo random. ARM64 nativo.
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="queue-browser:latest"
COMPOSE_FILE="docker-compose.yml"
PROJECT="queue"
BASE_PORT=6080
PIA_SERVERLIST="https://serverlist.piaservers.net/vpninfo/servers/v6"
VPN_COUNTRIES="${VPN_COUNTRIES:-US AR UY CL BR}"
UAS_FILE="user-agents.txt"
TARGET_URL="${TARGET_URL:-https://www.deportick.com}"
OPEN_DELAY_MAX="${OPEN_DELAY_MAX:-30}"
UA_VERSIONS="${UA_VERSIONS:-3}"
ROTATE_MIN="${ROTATE_MIN:-15}"
ROTATE_MAX="${ROTATE_MAX:-40}"
WATCH_PID=".watch.pid"
WATCH_LOG="watch.log"
[ "$ROTATE_MIN" -ge 0 ] 2>/dev/null && [ "$ROTATE_MAX" -ge "$ROTATE_MIN" ] 2>/dev/null || { ROTATE_MIN=15; ROTATE_MAX=40; }

usage() {
  cat <<EOF
Uso: ./queue.sh <comando>

Comandos:
  build        Construye la imagen del navegador (Alpine + Chromium + noVNC)
  up N         Genera docker-compose.yml y levanta N instancias
  down         Baja y elimina todas las instancias
  ips          Muestra la IP publica y pais de cada instancia
  urls         Muestra las URLs de noVNC de cada instancia
  status       Estado de los contenedores
  watch        Sigue los QUEUE_EVENT de cada instancia: si la pagina devuelve 403
               rota su IP+UA y reintenta; si pide captcha/MFA abre su noVNC
               (up lo lanza solo en background, log en $WATCH_LOG)

Config:
  .env             PIA_USER / PIA_PASS y DEPORTICK_USER / DEPORTICK_PASS (copiar de .env.example)
  user-agents.txt  Plantillas de user agents ({V} = version de Chromium, uno distinto por instancia)

Env opcionales:
  TARGET_URL       URL a abrir tras el delay random (default: https://www.deportick.com)
  OPEN_DELAY_MAX   Delay maximo en segundos antes de abrir TARGET_URL (default: 30)
  VPN_COUNTRIES    Paises (codigo ISO) de donde salen las IPs, se sortea pais y despues servidor (default: US AR UY CL BR)
  UA_VERSIONS      Cuantas versiones mayores de Chrome usar hacia atras desde la real (default: 3)
  DEPLOY_INTERVAL  Segundos entre el arranque de cada instancia en up (default: 100)
  VPN_WAIT         Segundos maximos esperando que cada VPN quede healthy en up (default: 120)
  ROTATE_MIN       Espera minima tras un 403 antes de reintentar con IP+UA nueva (default: 15)
  ROTATE_MAX       Espera maxima tras un 403 antes de reintentar con IP+UA nueva (default: 40)
EOF
  exit 1
}

# Lee un archivo de pool ignorando comentarios y lineas vacias
read_pool() {
  grep -v -e '^#' -e '^[[:space:]]*$' "$1"
}

# Mezcla random las lineas de stdin
shuffle() {
  awk -v seed="$RANDOM" 'BEGIN{srand(seed)}{print rand()"\t"$0}' | sort -n | cut -f2-
}

# Expande las plantillas {V} con la version mayor real de Chromium de la imagen
# y las UA_VERSIONS-1 anteriores, sin duplicados
ua_pool() {
  local major
  major=$(docker run --rm --entrypoint chromium "$IMAGE" --version | sed -n 's/^Chromium \([0-9]*\)\..*/\1/p')
  [ -n "$major" ] || { echo "ERROR: no pude detectar la version de Chromium de $IMAGE" >&2; exit 1; }
  read_pool "$UAS_FILE" | awk -v m="$major" -v n="$UA_VERSIONS" '{for(i=0;i<n;i++){l=$0; gsub(/\{V\}/, m-i, l); print l}}' | sort -u
}

# Devuelve hasta $1 lineas "IP\tregion" de servidores OpenVPN UDP online ahora
# mismo segun PIA en VPN_COUNTRIES. La lista embebida en gluetun queda vieja, por
# eso se fija cada VPN a una IP viva. Sorteo: pais random (entre los que les
# quedan servidores) y servidor random de ese pais, sin repetir, asi US no se
# come todo por tener mas servidores. $2 opcional: IP a excluir del sorteo.
pick_servers() {
  curl -fsS --max-time 20 "$PIA_SERVERLIST" | head -1 |
    jq -r --arg c "$VPN_COUNTRIES" '($c | ascii_upcase | split(" ") | map(select(. != ""))) as $cs
      | .regions[] | select((.offline | not) and (.country as $x | $cs | index($x)))
      | .country as $k | .name as $r | .servers.ovpnudp[]? | "\($k)\t\(.ip)\t\($r)"' |
    shuffle | awk -F'\t' '!seen[$2]++' |
    awk -F'\t' -v n="$1" -v excl="${2:-}" -v seed="$RANDOM" 'BEGIN{srand(seed)}
      $2 == excl { next }
      { if (!($1 in cnt)) ks[nk++] = $1; srv[$1, cnt[$1]++] = $2 "\t" $3 }
      END { for (i = 0; i < n && nk > 0; i++) {
        j = int(rand() * nk); k = ks[j]; print srv[k, --cnt[k]]
        if (!cnt[k]) ks[j] = ks[--nk]
      } }'
}

# Valor de una env KEY dentro del bloque "  <svc>:" del compose generado
compose_env() {
  awk -v pre="  $1:" -v key="$2" '
    index($0, pre) == 1 { inb = 1; next }
    /^  [a-z]/ { inb = 0 }
    inb && index($0, key "=") { sub(".*" key "=", ""); print; exit }
  ' "$COMPOSE_FILE"
}

# Rota la instancia $1: sortea un servidor PIA y un UA nuevos (distintos de los
# actuales), los escribe en $COMPOSE_FILE y recrea vpn$i + browser$i.
# $2 opcional: dir del watcher para serializar la edicion del compose (varias
# instancias pueden rotar a la vez sin pisarse entre si).
rotate_instance() {
  local i="$1" rot="${2:-}" old_ip old_ua s ip region ua deadline tmp
  old_ip=$(compose_env "vpn$i" OPENVPN_ENDPOINT_IP)
  old_ua=$(compose_env "browser$i" USER_AGENT)
  s=$(pick_servers 1 "$old_ip" || true)
  [ -n "$s" ] || { echo "  instancia $i: no hay servidores PIA nuevos para rotar"; return 1; }
  ip="${s%%$'\t'*}"; region="${s#*$'\t'}"
  ua=$( { ua_pool | shuffle | grep -vxF "$old_ua" || true; } | head -1)
  [ -n "$ua" ] || ua=$(ua_pool | shuffle | head -1)
  [ -n "$ua" ] || { echo "  instancia $i: pool de user agents vacio"; return 1; }

  tmp=$(mktemp "${TMPDIR:-/tmp}/queue-compose.XXXXXX")
  [ -z "$rot" ] || while ! mkdir "$rot/compose.d" 2>/dev/null; do sleep 1; done
  awk -v i="$i" -v ip="$ip" -v region="$region" -v ua="$ua" '
    BEGIN { vp = "  vpn" i ":"; bp = "  browser" i ":" }
    index($0, vp) == 1 {
      inv = 1; inb = 0
      if (index($0, "#")) $0 = substr($0, 1, index($0, "#")) " " region
      else $0 = $0 " # " region
      print; next
    }
    index($0, bp) == 1 { inb = 1; inv = 0; print; next }
    /^  [a-z]/ { inv = 0; inb = 0 }
    inv && /OPENVPN_ENDPOINT_IP=/ {
      print substr($0, 1, index($0, "OPENVPN_ENDPOINT_IP=") + 19) ip; next
    }
    inb && /^[[:space:]]*- USER_AGENT=/ {
      print substr($0, 1, index($0, "USER_AGENT=") + 10) ua; next
    }
    { print }
  ' "$COMPOSE_FILE" > "$tmp" && mv "$tmp" "$COMPOSE_FILE"
  [ -z "$rot" ] || rmdir "$rot/compose.d" 2>/dev/null

  echo "$(date +%H:%M:%S) instancia $i rotada -> $region ($ip) | UA: ${ua:0:70}..."
  docker compose -f "$COMPOSE_FILE" rm -fs "browser$i" >/dev/null 2>&1 || true
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate "vpn$i" >/dev/null 2>&1
  deadline=$(( SECONDS + ${VPN_WAIT:-120} ))
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$PROJECT-vpn$i-1" 2>/dev/null)" = healthy ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "  instancia $i: vpn$i no quedo healthy, browser$i no arranca"; return 1; }
    sleep 3
  done
  docker compose -f "$COMPOSE_FILE" up -d "browser$i" >/dev/null 2>&1
}

generate_compose() {
  local n="$1"
  [ -f .env ] || { echo "ERROR: falta .env (copia .env.example y pone tus credenciales PIA)"; exit 1; }

  SERVERS=()
  while IFS= read -r line; do SERVERS+=("$line"); done < <(pick_servers "$n")
  local uas
  uas=$(ua_pool)
  UAS=()
  while IFS= read -r line; do UAS+=("$line"); done < <(echo "$uas" | shuffle)
  local ns=${#SERVERS[@]} nu=${#UAS[@]}
  [ "$ns" -gt 0 ] || { echo "ERROR: no hay servidores PIA online para VPN_COUNTRIES=$VPN_COUNTRIES (o no pude bajar $PIA_SERVERLIST)"; exit 1; }
  [ "$nu" -gt 0 ] || { echo "ERROR: pool de user agents vacio"; exit 1; }
  [ "$n" -le "$ns" ] || { echo "ERROR: pediste $n instancias pero PIA tiene solo $ns servidores online en $VPN_COUNTRIES"; exit 1; }
  [ "$n" -le "$nu" ] || { echo "ERROR: pediste $n instancias pero solo hay $nu user agents distintos (subi UA_VERSIONS o agrega plantillas a $UAS_FILE)"; exit 1; }

  {
    echo "# Generado por queue.sh - no editar a mano"
    echo "name: $PROJECT"
    echo "services:"
    for i in $(seq 1 "$n"); do
      local ip="${SERVERS[$((i-1))]%%$'\t'*}" region="${SERVERS[$((i-1))]#*$'\t'}"
      local ua="${UAS[$(( (i-1) % nu ))]}"
      local port=$(( BASE_PORT + i ))
      cat <<EOF
  vpn$i: # $region
    image: qmcgaw/gluetun:v3
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=private internet access
      - OPENVPN_USER=\${PIA_USER}
      - OPENVPN_PASSWORD=\${PIA_PASS}
      - OPENVPN_ENDPOINT_IP=$ip
      - FIREWALL_INPUT_PORTS=6080
    ports:
      - "127.0.0.1:$port:6080"
    restart: unless-stopped

  browser$i:
    image: $IMAGE
    network_mode: "service:vpn$i"
    depends_on:
      vpn$i:
        condition: service_healthy
    environment:
      - USER_AGENT=$ua
      - SCREEN_W=1280
      - SCREEN_H=800
      - TARGET_URL=$TARGET_URL
      - OPEN_DELAY_MAX=$OPEN_DELAY_MAX
      - DEPORTICK_USER=\${DEPORTICK_USER:-}
      - DEPORTICK_PASS=\${DEPORTICK_PASS:-}
    shm_size: "512m"
    mem_limit: 1200m
    restart: unless-stopped

EOF
    done
  } > "$COMPOSE_FILE"
  echo "Generado $COMPOSE_FILE con $n instancias."
}

vnc_url() {
  echo "http://localhost:$(( BASE_PORT + $1 ))/vnc.html?autoconnect=1&resize=scale"
}

cmd_urls() {
  local n
  n=$(docker compose -f "$COMPOSE_FILE" ps --services 2>/dev/null | grep -c '^browser' || true)
  for i in $(seq 1 "$n"); do
    echo "instancia $i -> $(vnc_url "$i")"
  done
}

open_url() {
  if command -v open >/dev/null; then open "$1"
  elif command -v xdg-open >/dev/null; then xdg-open "$1" >/dev/null 2>&1
  fi
}

# Sigue los logs de los browsers y reacciona a los QUEUE_EVENT que emiten
# monitor.mjs (403) y login.mjs (captcha/mfa/login_*)
cmd_watch() {
  local rot_dir
  rot_dir=$(mktemp -d "${TMPDIR:-/tmp}/queue-rotate.XXXXXX")
  echo "$(date +%H:%M:%S) watcher iniciado"
  docker compose -f "$COMPOSE_FILE" logs -f --tail 0 --no-color 2>/dev/null |
  while IFS= read -r line; do
    [[ "$line" == browser* && "$line" == *"QUEUE_EVENT "* ]] || continue
    local i="${line#browser}" ev="${line##*QUEUE_EVENT }" ts
    i="${i%%[!0-9]*}"
    ts=$(date +%H:%M:%S)
    case "$ev" in
      captcha|mfa)
        # Si esta rotando por un 403 la sesion muere igual, no abrir el VNC
        if [ -d "$rot_dir/$i.d" ]; then
          echo "$ts instancia $i pide $ev (rotando, no abro VNC)"
        else
          echo "$ts instancia $i pide $ev -> abriendo $(vnc_url "$i")"
          open_url "$(vnc_url "$i")"
        fi
        ;;
      403)
        # Una rotacion a la vez por instancia; el lock se libera al terminar
        if mkdir "$rot_dir/$i.d" 2>/dev/null; then
          local wait_s=$(( ROTATE_MIN + RANDOM % (ROTATE_MAX - ROTATE_MIN + 1) ))
          echo "$ts instancia $i recibio 403 -> nueva IP+UA en ${wait_s}s"
          ( sleep "$wait_s"; rotate_instance "$i" "$rot_dir"; rmdir "$rot_dir/$i.d" ) &
        fi
        ;;
      login_ok)    echo "$ts instancia $i logueada" ;;
      login_error) echo "$ts instancia $i error de login (ver: docker compose logs browser$i)" ;;
      *)           echo "$ts instancia $i: $ev" ;;
    esac
  done
}

stop_watcher() {
  [ -f "$WATCH_PID" ] || return 0
  local pid
  pid=$(cat "$WATCH_PID")
  pkill -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  rm -f "$WATCH_PID"
}

start_watcher() {
  stop_watcher
  nohup "./$(basename "$0")" watch >> "$WATCH_LOG" 2>&1 &
  echo $! > "$WATCH_PID"
}

cmd_ips() {
  local n
  n=$(docker compose -f "$COMPOSE_FILE" ps --services 2>/dev/null | grep -c '^browser' || true)
  for i in $(seq 1 "$n"); do
    # IP que ya detecto gluetun (API local, sin salir a internet); si no la da,
    # ipinfo.io con reintentos porque un timeout suelto no significa VPN caida
    local info ip="" country="" try
    info=$(docker compose -f "$COMPOSE_FILE" exec -T "browser$i" \
      wget -qO- --timeout=5 "http://127.0.0.1:8000/v1/publicip/ip" 2>/dev/null || true)
    ip=$(echo "$info" | jq -r '.public_ip // empty' 2>/dev/null || true)
    country=$(echo "$info" | jq -r '.country // empty' 2>/dev/null || true)
    for try in 1 2 3; do
      [ -z "$ip" ] || break
      info=$(docker compose -f "$COMPOSE_FILE" exec -T "browser$i" \
        wget -qO- --timeout=10 "https://ipinfo.io/json" 2>/dev/null || true)
      ip=$(echo "$info" | jq -r '.ip // empty' 2>/dev/null || true)
      country=$(echo "$info" | jq -r '.country // empty' 2>/dev/null || true)
    done
    if [ -n "$ip" ]; then
      local ua
      ua=$(docker compose -f "$COMPOSE_FILE" exec -T "browser$i" sh -c 'echo $USER_AGENT' 2>/dev/null | cut -c1-60)
      printf "instancia %-3s ip=%-16s pais=%-14s ua=%s...\n" "$i" "$ip" "$country" "$ua"
    else
      echo "instancia $i   (sin respuesta, VPN todavia conectando?)"
    fi
  done
}

case "${1:-}" in
  build)
    docker build -t "$IMAGE" browser/
    ;;
  up)
    n="${2:-}"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || { echo "Uso: ./queue.sh up N"; exit 1; }
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" browser/
    generate_compose "$n"
    # VPNs de a una, una instancia nueva cada DEPLOY_INTERVAL segundos; cada browser
    # arranca solo si su VPN quedo healthy. No se usa "up --wait": corta con el
    # primer unhealthy aunque gluetun siga reintentando.
    login=false
    grep -q '^DEPORTICK_USER=..*' .env && login=true
    for i in $(seq 1 "$n"); do
      if [ "$i" -gt 1 ]; then
        wait_s=$(( next_at - SECONDS ))
        if [ "$wait_s" -gt 0 ]; then
          echo "  proxima instancia en ${wait_s}s ($(date -v+"${wait_s}"S +%H:%M:%S 2>/dev/null || date -d "+${wait_s} sec" +%H:%M:%S))"
          sleep "$wait_s"
        fi
      fi
      next_at=$(( SECONDS + ${DEPLOY_INTERVAL:-100} ))
      echo "$(date +%H:%M:%S) conectando vpn$i ($(sed -n "s/^  vpn$i: # //p" "$COMPOSE_FILE"))..."
      docker compose -f "$COMPOSE_FILE" up -d "vpn$i" 2>/dev/null
      deadline=$(( SECONDS + ${VPN_WAIT:-120} ))
      until [ "$(docker inspect -f '{{.State.Health.Status}}' "$PROJECT-vpn$i-1" 2>/dev/null)" = healthy ]; do
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 3
      done
      if [ "$SECONDS" -lt "$deadline" ]; then
        docker compose -f "$COMPOSE_FILE" up -d "browser$i" 2>/dev/null
        echo "  ok"
      else
        echo "  AVISO: vpn$i no quedo healthy en ${VPN_WAIT:-120}s, browser$i no arranca (docker compose logs vpn$i)"
      fi
      # El watcher arranca con la primera instancia (sin contenedores "logs -f" termina)
      if [ "$i" -eq 1 ]; then
        start_watcher
        echo "  watcher activo (log: $WATCH_LOG): ante un 403 rota IP+UA y reintenta en ${ROTATE_MIN}-${ROTATE_MAX}s"
        $login && echo "  login automatico activo: si alguna instancia pide captcha se abre su noVNC"
      fi
    done
    echo
    echo "Instancias levantadas. URLs de noVNC:"
    cmd_urls
    echo
    echo "Tip: ./queue.sh ips para ver la IP de salida de cada una (esperar ~30s a que conecte la VPN)."
    ;;
  down)
    stop_watcher
    [ -f "$COMPOSE_FILE" ] || { echo "No hay $COMPOSE_FILE, nada que bajar."; exit 0; }
    docker compose -f "$COMPOSE_FILE" down
    ;;
  watch)
    cmd_watch
    ;;
  ips)
    cmd_ips
    ;;
  urls)
    cmd_urls
    ;;
  status)
    docker compose -f "$COMPOSE_FILE" ps
    ;;
  *)
    usage
    ;;
esac
