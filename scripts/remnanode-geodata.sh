#!/usr/bin/env bash
# remnanode-geodata.sh — качает geodata на сервер с remnanode и подкладывает их Xray.
#
# Файлов ЧЕТЫРЕ, из двух источников:
#   custom-geosite.dat  — наш: ADS, ADS-NETWORKS, BLOCK-DOMAINS, SYSTEM, CONNECTIVITY, AI,
#                         TWITCH-ADS, RU (добавка). Это наша политика роутинга.
#   custom-geoip.dat    — наш: подсети по категориям из data/geoip (TIKTOK, ...).
#                         Нужен, когда сервис ловится только по IP, а не по домену.
#   roscom-geoip.dat    — hydraponique/roscomvpn-geoip: ~15 000 подсетей РФ/РБ,
#                         пересобирается ежедневно. Массовый RU-роутинг по IP.
#   roscom-geosite.dat  — hydraponique/roscomvpn-geosite: whitelist, category-ru,
#                         category-geoblock-ru, посервисные списки.
#
# Имена НАРОЧНО не geosite.dat/geoip.dat: под этими именами лежат дефолтные
# ассеты Xray, и подмена их сломала бы обычные geosite:/geoip: правила.
#
#   sudo ./remnanode-geodata.sh install    # первичная установка + таймер обновления
#   sudo ./remnanode-geodata.sh update     # разово обновить (это же дёргает таймер)
#   sudo ./remnanode-geodata.sh status     # что лежит на диске
#
# Настройки можно переопределить переменными окружения, например:
#   REPO=ivan/geodata CONTAINER=remnanode sudo -E ./remnanode-geodata.sh install
#   UPSTREAM=0 sudo -E ./remnanode-geodata.sh update   # только наш файл, без roscomvpn

set -euo pipefail

# ─────────── настройки ───────────
REPO="${REPO:-Mrzalupa-lolz/geositez}"           # наш репозиторий
UPSTREAM="${UPSTREAM:-1}"                        # 0 — не качать чужие списки
UPSTREAM_GEOIP="${UPSTREAM_GEOIP:-hydraponique/roscomvpn-geoip}"
UPSTREAM_GEOSITE="${UPSTREAM_GEOSITE:-hydraponique/roscomvpn-geosite}"
DEST="${DEST:-/opt/remnanode/geodata}"           # где файлы лежат на хосте
CONTAINER="${CONTAINER:-remnanode}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/remnanode/docker-compose.yml}"
RESTART="${RESTART:-1}"                          # 1 — рестартить ноду при новой ревизии

# Что качать: пары "URL|имя файла на диске", через пробел.
# Если GitHub с сервера не открывается — подставь зеркало jsDelivr:
#   https://cdn.jsdelivr.net/gh/ВЛАДЕЛЕЦ/РЕПО@release/ИМЯ.dat
if [ -z "${SOURCES:-}" ]; then
  SOURCES="custom-geosite.dat|custom-geosite.dat custom-geoip.dat|custom-geoip.dat"
  if [ "$UPSTREAM" = "1" ]; then
    SOURCES="$SOURCES https://github.com/${UPSTREAM_GEOIP}/releases/latest/download/geoip.dat|roscom-geoip.dat"
    SOURCES="$SOURCES https://github.com/${UPSTREAM_GEOSITE}/releases/latest/download/geosite.dat|roscom-geosite.dat"
  fi
fi

SELF_PATH="/usr/local/bin/remnanode-geodata.sh"
XRAY_ASSET_DIR="/usr/local/share/xray"
STATE_FILE="${DEST}/.source-revision"
if [ "$RESTART" != 1 ]; then STATE_FILE="${STATE_FILE}.no-restart"; fi
# ─────────────────────────────────

# имена файлов из SOURCES
source_names() { local s; for s in $SOURCES; do echo "${s##*|}"; done; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = "0" ] || die "запусти через sudo"; }

check_repo() {
  case "$REPO" in
    OWNER/REPO|*/REPO|"") die "не задан репозиторий: впиши REPO=твой-логин/твой-репо в скрипт или в окружение" ;;
  esac
}

download() {
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 -o "$2" "$1" \
    || die "не скачался $1"
}

fetch_one() {
  local url="$1" name="$2" tmp="$3"
  download "$url" "$tmp"
  # .dat — это protobuf, он всегда начинается с байта 0x0A и не бывает пустым
  if [ ! -s "$tmp" ]; then
    die "$name скачался пустым"
  fi
  if [ "$(head -c 1 "$tmp" | od -An -tx1 | tr -d ' ')" != "0a" ]; then
    die "$name не похож на geodata-файл (пришла HTML-страница вместо .dat?)"
  fi
}

install_one() {
  local tmp="$1" name="$2"
  if cmp -s "$tmp" "${DEST}/${name}"; then
    log "$name — без изменений"
    return
  fi

  # Пишем содержимое поверх существующего файла (не mv!): файл примонтирован
  # в контейнер bind-mount'ом, и подмена через rename сломала бы монтирование.
  cat "$tmp" >"${DEST}/${name}"
  chmod 0644 "${DEST}/${name}"
  log "$name — обновлён ($(stat -c%s "${DEST}/${name}") байт)"
}

restart_node() {
  [ "$RESTART" = "1" ] || { warn "RESTART=0 — нода не перезапущена, новые списки подхватятся позже"; return 0; }
  if [ -f "$COMPOSE_FILE" ] && docker compose version >/dev/null 2>&1; then
    log "перезапускаю ноду через docker compose"
    docker compose -f "$COMPOSE_FILE" restart "$CONTAINER"
  else
    log "перезапускаю контейнер $CONTAINER"
    docker restart "$CONTAINER" >/dev/null
  fi
}

sync_release() (
  need_root; check_repo
  mkdir -p "$DEST"
  local mode="$1" release revision applied='' applied_release='' base staging s name url
  exec 9>"${DEST}/.update.lock"
  flock -x 9
  release="$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --exit-code "https://github.com/${REPO}.git" refs/heads/release)"
  release="${release%%[[:space:]]*}"
  [[ "$release" =~ ^[0-9a-f]{40}$ ]] || die "не удалось определить коммит ветки release"
  if [ -f "$STATE_FILE" ]; then
    read -r applied applied_release <"$STATE_FILE"
  fi
  for name in $(source_names); do
    if [ ! -s "${DEST}/${name}" ]; then applied=''; applied_release=''; break; fi
  done
  if [ "$mode" = update ] && [ "$release" = "$applied_release" ]; then
    return
  fi

  staging="$(mktemp -d "${DEST}/.stage.XXXXXX")"
  trap 'rm -rf -- "$staging"' EXIT
  base="https://raw.githubusercontent.com/${REPO}/${release}"
  download "${base}/source-revision.txt" "${staging}/revision"
  revision="$(cat "${staging}/revision")"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "некорректная ревизия в source-revision.txt"
  if [ "$mode" = update ] && [ "$revision" = "$applied" ]; then
    printf '%s %s\n' "$revision" "$release" >"${staging}/state"
    mv -f "${staging}/state" "$STATE_FILE"
    return
  fi

  download "${base}/checksums.txt" "${staging}/checksums.txt"
  for s in $SOURCES; do
    name="${s##*|}"
    url="${s%%|*}"
    if [ "$url" = "$name" ]; then url="${base}/${name}"; fi
    fetch_one "$url" "$name" "${staging}/${name}"
  done
  (cd "$staging" && sha256sum --check --ignore-missing checksums.txt) \
    || die "контрольные суммы geodata не совпали"
  for name in $(source_names); do install_one "${staging}/${name}" "$name"; done
  if [ "$mode" = update ]; then
    restart_node
    printf '%s %s\n' "$revision" "$release" >"${staging}/state"
    mv -f "${staging}/state" "$STATE_FILE"
    log "применена ревизия $revision"
  fi
)

cmd_status() {
  check_repo
  echo "наш репозиторий : $REPO"
  echo "чужие списки    : $([ "$UPSTREAM" = "1" ] && echo "$UPSTREAM_GEOIP + $UPSTREAM_GEOSITE" || echo "отключены (UPSTREAM=0)")"
  echo "каталог         : $DEST"
  if [ -f "$STATE_FILE" ]; then
    printf 'ревизия         : %s\n' "$(cut -d' ' -f1 "$STATE_FILE")"
  fi
  local f
  for f in $(source_names); do
    if [ -f "${DEST}/${f}" ]; then
      printf '  %-24s %8s байт  %s\n' "$f" "$(stat -c%s "${DEST}/${f}")" "$(date -r "${DEST}/${f}" '+%F %T')"
    else
      printf '  %-24s НЕТ\n' "$f"
    fi
  done
  echo
  echo "внутри контейнера $CONTAINER:"
  docker exec "$CONTAINER" ls -la "$XRAY_ASSET_DIR" 2>/dev/null || warn "контейнер не запущен или не найден"
  echo
  systemctl status remnanode-geodata.timer --no-pager 2>/dev/null | head -5 || true
}

install_timer() {
  cat >/etc/systemd/system/remnanode-geodata.service <<EOF
[Unit]
Description=Обновление custom geodata для remnanode
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=REPO=${REPO}
Environment=DEST=${DEST}
Environment=CONTAINER=${CONTAINER}
Environment=COMPOSE_FILE=${COMPOSE_FILE}
Environment=RESTART=${RESTART}
Environment="SOURCES=${SOURCES}"
ExecStart=${SELF_PATH} update
EOF

  cat >/etc/systemd/system/remnanode-geodata.timer <<'EOF'
[Unit]
Description=Проверка опубликованной ревизии geodata для remnanode

[Timer]
OnActiveSec=1min
OnUnitInactiveSec=1min
AccuracySec=1s
RandomizedDelaySec=15s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable remnanode-geodata.timer
  systemctl restart remnanode-geodata.timer
  log "таймер поставлен: systemctl list-timers remnanode-geodata.timer"
}

cmd_install() {
  need_root; check_repo
  command -v docker >/dev/null || die "docker не найден"
  command -v curl   >/dev/null || die "нет curl: apt install -y curl"

  command -v git    >/dev/null || die "git не найден"
  local f
  for f in $(source_names); do
    if [ ! -s "${DEST}/${f}" ]; then
      sync_release install
      break
    fi
  done

  # положить сам скрипт в /usr/local/bin, чтобы systemd его звал
  if [ "$(readlink -f "$0")" != "$SELF_PATH" ]; then
    install -m 0755 "$0" "$SELF_PATH"
    log "скрипт скопирован в $SELF_PATH"
  fi

  install_timer

  # проверить, примонтированы ли файлы в контейнер
  local missing=0
  for f in $(source_names); do
    docker exec "$CONTAINER" test -f "${XRAY_ASSET_DIR}/${f}" 2>/dev/null || missing=1
  done

  if [ "$missing" = "1" ]; then
    echo
    warn "файлы ещё не видны внутри контейнера — добавь монтирование в ${COMPOSE_FILE}:"
    echo
    echo "    volumes:"
    for f in $(source_names); do
      echo "      - '${DEST}/${f}:${XRAY_ASSET_DIR}/${f}'"
    done
    echo
    echo "  ВАЖНО: монтировать только отдельные файлы, не всю папку —"
    echo "  том на каталог затрёт дефолтные geosite.dat/geoip.dat."
    echo
    echo "  потом:  docker compose -f ${COMPOSE_FILE} up -d --force-recreate"
  else
    log "файлы видны внутри контейнера — всё на месте"
  fi
}

case "${1:-update}" in
  install) cmd_install ;;
  update)  sync_release update ;;
  status)  cmd_status ;;
  *) die "использование: $0 {install|update|status}" ;;
esac
