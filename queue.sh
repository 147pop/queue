#!/usr/bin/env bash
# queue.sh - Levanta N instancias Chromium dockerizadas, cada una detras de
# PIA VPN (gluetun) con region random y user agent legitimo random. ARM64 nativo.
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="queue-browser:latest"
COMPOSE_FILE="docker-compose.yml"
PROJECT="queue"
BASE_PORT=6080
REGIONS_FILE="regions.txt"
UAS_FILE="user-agents.txt"

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

Config:
  .env             PIA_USER / PIA_PASS (copiar de .env.example)
  regions.txt      Pool de regiones PIA (una random por instancia, sin repetir)
  user-agents.txt  Pool de user agents (uno random por instancia)
EOF
  exit 1
}

# Lee un archivo de pool ignorando comentarios y lineas vacias, mezclado random
shuffled_pool() {
  grep -v -e '^#' -e '^[[:space:]]*$' "$1" | awk -v seed="$RANDOM" 'BEGIN{srand(seed)}{print rand()"\t"$0}' | sort -n | cut -f2-
}

generate_compose() {
  local n="$1"
  [ -f .env ] || { echo "ERROR: falta .env (copia .env.example y pone tus credenciales PIA)"; exit 1; }

  REGIONS=()
  while IFS= read -r line; do REGIONS+=("$line"); done < <(shuffled_pool "$REGIONS_FILE")
  UAS=()
  while IFS= read -r line; do UAS+=("$line"); done < <(shuffled_pool "$UAS_FILE")
  local nr=${#REGIONS[@]} nu=${#UAS[@]}
  [ "$nr" -gt 0 ] && [ "$nu" -gt 0 ] || { echo "ERROR: pools vacios"; exit 1; }

  {
    echo "# Generado por queue.sh - no editar a mano"
    echo "name: $PROJECT"
    echo "services:"
    for i in $(seq 1 "$n"); do
      local region="${REGIONS[$(( (i-1) % nr ))]}"
      local ua="${UAS[$(( (i-1) % nu ))]}"
      local port=$(( BASE_PORT + i ))
      cat <<EOF
  vpn$i:
    image: qmcgaw/gluetun:v3
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=private internet access
      - OPENVPN_USER=\${PIA_USER}
      - OPENVPN_PASSWORD=\${PIA_PASS}
      - SERVER_REGIONS=$region
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
    shm_size: "512m"
    mem_limit: 1200m
    restart: unless-stopped

EOF
    done
  } > "$COMPOSE_FILE"
  echo "Generado $COMPOSE_FILE con $n instancias."
}

cmd_urls() {
  local n
  n=$(docker compose -f "$COMPOSE_FILE" ps --services 2>/dev/null | grep -c '^browser' || true)
  for i in $(seq 1 "$n"); do
    echo "instancia $i -> http://localhost:$(( BASE_PORT + i ))/vnc.html?autoconnect=1&resize=scale"
  done
}

cmd_ips() {
  local n
  n=$(docker compose -f "$COMPOSE_FILE" ps --services 2>/dev/null | grep -c '^browser' || true)
  for i in $(seq 1 "$n"); do
    local info
    info=$(docker compose -f "$COMPOSE_FILE" exec -T "browser$i" \
      wget -qO- --timeout=10 "https://ipinfo.io/json" 2>/dev/null || echo "")
    if [ -n "$info" ]; then
      local ip country ua
      ip=$(echo "$info" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')
      country=$(echo "$info" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')
      ua=$(docker compose -f "$COMPOSE_FILE" exec -T "browser$i" sh -c 'echo $USER_AGENT' 2>/dev/null | cut -c1-60)
      printf "instancia %-3s ip=%-16s pais=%-3s ua=%s...\n" "$i" "$ip" "$country" "$ua"
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
    docker compose -f "$COMPOSE_FILE" up -d
    echo
    echo "Instancias levantadas. URLs de noVNC:"
    cmd_urls
    echo
    echo "Tip: ./queue.sh ips para ver la IP de salida de cada una (esperar ~30s a que conecte la VPN)."
    ;;
  down)
    [ -f "$COMPOSE_FILE" ] || { echo "No hay $COMPOSE_FILE, nada que bajar."; exit 0; }
    docker compose -f "$COMPOSE_FILE" down
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
