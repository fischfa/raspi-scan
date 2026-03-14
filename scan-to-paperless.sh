#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

CONFIG_FILE="${SCAN_TO_PAPERLESS_CONFIG:-/etc/scan-to-paperless.conf}"

log() {
  local level="$1"; shift
  local msg="$*"
  logger -t "${LOG_TAG:-scan-to-paperless}" "[$level] $msg" || true
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" >&2
}

die() {
  log "ERROR" "$*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"
}

str_to_bool() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off|"") return 1 ;;
    *) die "Ungültiger Bool-Wert: '$1'" ;;
  esac
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || die "Konfigurationsdatei nicht lesbar: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${LOG_TAG:=scan-to-paperless}"
  : "${SCAN_DEVICE:=}"
  : "${SCAN_SOURCE:=ADF Duplex}"
  : "${SCAN_MODE:=Gray}"
  : "${SCAN_RESOLUTION:=300}"
  : "${SCAN_FORMAT:=tiff}"
  : "${SCAN_PAGE_WIDTH:=210}"
  : "${SCAN_PAGE_HEIGHT:=297}"
  : "${SCAN_EXTRA_OPTS:=}"
  : "${REMOVE_BLANK_PAGES:=false}"
  : "${REVERSE_PAGE_ORDER:=false}"
  : "${PDF_ROTATION:=0}"
  : "${BLANK_THRESHOLD:=0.0012}"
  : "${MIN_PAGES_TO_FILTER:=2}"
  : "${EXPECTED_SCANBD_ACTION_REGEX:=^scan$}"
  : "${UPLOAD_METHOD:=filesystem}"
  : "${TARGET_DIR:=/mnt/paperless-consume}"
  : "${TARGET_SUBDIR:=}"
  : "${AUTO_CREATE_TARGET_DIR:=false}"
  : "${REQUIRE_TARGET_MOUNTPOINT:=}"
  : "${SPOOL_DIR:=/var/lib/scan-to-paperless/spool}"
  : "${ARCHIVE_DIR:=/var/lib/scan-to-paperless/archive}"
  : "${KEEP_LOCAL_COPY:=false}"
  : "${FILE_PREFIX:=scan}"
  : "${SFTP_HOST:=}"
  : "${SFTP_PORT:=22}"
  : "${SFTP_USER:=}"
  : "${SFTP_REMOTE_DIR:=}"
  : "${SFTP_IDENTITY_FILE:=/root/.ssh/paperless_scan}"
  : "${SFTP_STRICT_HOSTKEY:=accept-new}"
  : "${SFTP_CREATE_REMOTE_DIR:=false}"
  : "${LOCK_FILE:=/var/lib/scan-to-paperless/scan-to-paperless.lock}"
}

validate_config() {
  case "${UPLOAD_METHOD,,}" in
    filesystem|sftp) ;;
    *) die "UPLOAD_METHOD muss 'filesystem' oder 'sftp' sein" ;;
  esac

  [[ "$SCAN_FORMAT" == "tiff" ]] || die "SCAN_FORMAT muss aktuell 'tiff' sein"
  [[ "$SCAN_RESOLUTION" =~ ^[0-9]+$ ]] || die "SCAN_RESOLUTION muss numerisch sein"
  [[ "$SCAN_PAGE_WIDTH" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "SCAN_PAGE_WIDTH muss numerisch sein"
  [[ "$SCAN_PAGE_HEIGHT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "SCAN_PAGE_HEIGHT muss numerisch sein"
  [[ "$MIN_PAGES_TO_FILTER" =~ ^[0-9]+$ ]] || die "MIN_PAGES_TO_FILTER muss numerisch sein"
  [[ "$BLANK_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "BLANK_THRESHOLD muss numerisch sein"

  str_to_bool "$REMOVE_BLANK_PAGES" || true
  str_to_bool "$AUTO_CREATE_TARGET_DIR" || true
  str_to_bool "$KEEP_LOCAL_COPY" || true
  str_to_bool "$SFTP_CREATE_REMOTE_DIR" || true

  if [[ "${UPLOAD_METHOD,,}" == "filesystem" ]]; then
    [[ -n "$TARGET_DIR" ]] || die "TARGET_DIR fehlt"
  else
    [[ -n "$SFTP_HOST" ]] || die "SFTP_HOST fehlt"
    [[ -n "$SFTP_USER" ]] || die "SFTP_USER fehlt"
    [[ -n "$SFTP_REMOTE_DIR" ]] || die "SFTP_REMOTE_DIR fehlt"
    [[ -r "$SFTP_IDENTITY_FILE" ]] || die "SFTP_IDENTITY_FILE nicht lesbar: $SFTP_IDENTITY_FILE"
  fi
}

check_dependencies() {
  require_cmd scanimage
  require_cmd img2pdf
  require_cmd gs
  require_cmd qpdf
  require_cmd flock
  require_cmd logger
  require_cmd install
  require_cmd mv
  require_cmd awk
  require_cmd hostname
  require_cmd mktemp

  if [[ "${UPLOAD_METHOD,,}" == "filesystem" ]]; then
    if [[ -n "$REQUIRE_TARGET_MOUNTPOINT" ]]; then
      require_cmd mountpoint
    fi
  else
    require_cmd ssh
    require_cmd sftp
    require_cmd sed
  fi
}

detect_device() {
  if [[ -n "$SCAN_DEVICE" ]]; then
    DEVICE="$SCAN_DEVICE"
    return
  fi

  DEVICE="$(scanimage -L 2>/dev/null | awk -F"'" '/device `/{print $2; exit}')"
  [[ -n "$DEVICE" ]] || die "Kein Scanner gefunden (scanimage -L)."
}

prepare_paths() {
  mkdir -p "$SPOOL_DIR"
  if str_to_bool "$KEEP_LOCAL_COPY"; then
    mkdir -p "$ARCHIVE_DIR"
  fi

  host_short="$(hostname -s 2>/dev/null || hostname)"
  timestamp="$(date +'%Y%m%d-%H%M%S')"
  base_name="${FILE_PREFIX}_${host_short}_${timestamp}_$$"

  WORKDIR="$(mktemp -d /tmp/scan-to-paperless.XXXXXX)"
  RAW_PDF="$WORKDIR/raw.pdf"
  FINAL_PDF="$WORKDIR/final.pdf"
  SPOOL_PDF="$SPOOL_DIR/${base_name}.pdf"
  trap 'rm -rf "$WORKDIR"' EXIT
}

check_scanbd_action() {
  if [[ -n "${SCANBD_ACTION:-}" ]]; then
    if ! [[ "$SCANBD_ACTION" =~ $EXPECTED_SCANBD_ACTION_REGEX ]]; then
      die "Unerwartete scanbd-Aktion: '$SCANBD_ACTION' passt nicht auf $EXPECTED_SCANBD_ACTION_REGEX"
    fi
  fi
}

perform_scan() {
  local -a extra_opts=()
  if [[ -n "$SCAN_EXTRA_OPTS" ]]; then
    # Bewusst shell-artiges Splitting für einfache Konfiguration.
    # shellcheck disable=SC2206
    extra_opts=( $SCAN_EXTRA_OPTS )
  fi

  log "INFO" "Starte Scan: device='$DEVICE' source='$SCAN_SOURCE' mode='$SCAN_MODE' dpi='$SCAN_RESOLUTION' width='${SCAN_PAGE_WIDTH}mm' height='${SCAN_PAGE_HEIGHT}mm'"

  scanimage \
    -d "$DEVICE" \
    --source "$SCAN_SOURCE" \
    --mode "$SCAN_MODE" \
    --resolution "$SCAN_RESOLUTION" \
    --page-width "$SCAN_PAGE_WIDTH" \
    --page-height "$SCAN_PAGE_HEIGHT" \
    --format="$SCAN_FORMAT" \
    --batch="$WORKDIR/page-%04d.tif" \
    "${extra_opts[@]}"

  shopt -s nullglob
  PAGES=("$WORKDIR"/page-*.tif)
  shopt -u nullglob

  (( ${#PAGES[@]} > 0 )) || die "Es wurden keine Seiten gescannt. Ist der ADF leer oder die Quelle falsch?"

  img2pdf "${PAGES[@]}" -o "$RAW_PDF"
}

extract_non_blank_pages() {
  local pdf="$1"
  local threshold="$2"

  gs -q -o - -sDEVICE=inkcov "$pdf" 2>/dev/null | awk -v thr="$threshold" '
    /^[[:space:]]*[0-9]+\.[0-9]+[[:space:]]+[0-9]+\.[0-9]+[[:space:]]+[0-9]+\.[0-9]+[[:space:]]+[0-9]+\.[0-9]+/ {
      page++
      c=$1; m=$2; y=$3; k=$4;
      max=c; if (m>max) max=m; if (y>max) max=y; if (k>max) max=k;
      if (max > thr) {
        pages = (pages == "" ? page : pages "," page)
      }
    }
    END { print pages }
  '
}

remove_blank_pages_if_enabled() {
  local keep_pages=""

  if ! str_to_bool "$REMOVE_BLANK_PAGES"; then
    cp -f "$RAW_PDF" "$FINAL_PDF"
    return
  fi

  if (( ${#PAGES[@]} < MIN_PAGES_TO_FILTER )); then
    cp -f "$RAW_PDF" "$FINAL_PDF"
    return
  fi

  keep_pages="$(extract_non_blank_pages "$RAW_PDF" "$BLANK_THRESHOLD" || true)"

  if [[ -z "$keep_pages" ]]; then
    log "WARN" "Blank-Page-Filter würde alle Seiten entfernen; behalte daher alle Seiten. Threshold=$BLANK_THRESHOLD"
    cp -f "$RAW_PDF" "$FINAL_PDF"
    return
  fi

  qpdf "$RAW_PDF" --pages "$RAW_PDF" "$keep_pages" -- "$FINAL_PDF"
  log "INFO" "Leerseiten gefiltert. Behaltene Seiten: $keep_pages"
}

rotate_final_pdf_if_enabled() {
  case "${PDF_ROTATION:-0}" in
    ""|0)
      return
      ;;
    90|180|270)
      ;;
    *)
      die "PDF_ROTATION muss 0, 90, 180 oder 270 sein"
      ;;
  esac

  local rotated_pdf="$WORKDIR/rotated.pdf"
  qpdf "$FINAL_PDF" --rotate="+${PDF_ROTATION}:1-z" -- "$rotated_pdf"
  mv -f "$rotated_pdf" "$FINAL_PDF"
  log "INFO" "PDF um ${PDF_ROTATION} Grad gedreht"
}

reverse_page_order_if_enabled() {
  if ! str_to_bool "${REVERSE_PAGE_ORDER:-false}"; then
    return
  fi

  local reversed_pdf="$WORKDIR/reversed.pdf"
  qpdf --empty --pages "$FINAL_PDF" z-1 -- "$reversed_pdf"
  mv -f "$reversed_pdf" "$FINAL_PDF"
  log "INFO" "PDF-Seitenreihenfolge umgekehrt"
}

compose_target_dir() {
  if [[ -n "$TARGET_SUBDIR" ]]; then
    printf '%s/%s\n' "${1%/}" "${TARGET_SUBDIR#/}"
  else
    printf '%s\n' "${1%/}"
  fi
}

ensure_filesystem_target() {
  local target_dir
  target_dir="$(compose_target_dir "$TARGET_DIR")"

  if [[ -n "$REQUIRE_TARGET_MOUNTPOINT" ]]; then
    mountpoint -q "$REQUIRE_TARGET_MOUNTPOINT" || die "Erwarteter Mountpoint ist nicht gemountet: $REQUIRE_TARGET_MOUNTPOINT"
  fi

  if [[ ! -d "$target_dir" ]]; then
    if str_to_bool "$AUTO_CREATE_TARGET_DIR"; then
      mkdir -p "$target_dir"
    else
      die "Zielverzeichnis existiert nicht: $target_dir"
    fi
  fi

  [[ -w "$target_dir" ]] || die "Zielverzeichnis nicht beschreibbar: $target_dir"
  TARGET_DIR_EFFECTIVE="$target_dir"
}

deliver_filesystem() {
  local remote_tmp remote_final
  ensure_filesystem_target

  remote_tmp="$TARGET_DIR_EFFECTIVE/.${base_name}.pdf.part"
  remote_final="$TARGET_DIR_EFFECTIVE/${base_name}.pdf"

  install -m 0640 "$SPOOL_PDF" "$remote_tmp"
  mv -f "$remote_tmp" "$remote_final"
  log "INFO" "Datei bereitgestellt unter $remote_final"
}

ensure_remote_dir() {
  if ! str_to_bool "$SFTP_CREATE_REMOTE_DIR"; then
    return
  fi

  ssh \
    -i "$SFTP_IDENTITY_FILE" \
    -p "$SFTP_PORT" \
    -oBatchMode=yes \
    -oStrictHostKeyChecking="$SFTP_STRICT_HOSTKEY" \
    "$SFTP_USER@$SFTP_HOST" \
    "mkdir -p -- '$(printf "%s" "$SFTP_REMOTE_DIR" | sed "s/'/'\\''/g")'"
}

deliver_sftp() {
  local remote_dir remote_tmp remote_final

  ensure_remote_dir

  remote_dir="$(compose_target_dir "$SFTP_REMOTE_DIR")"
  remote_tmp="$remote_dir/.${base_name}.pdf.part"
  remote_final="$remote_dir/${base_name}.pdf"

  sftp \
    -i "$SFTP_IDENTITY_FILE" \
    -P "$SFTP_PORT" \
    -oBatchMode=yes \
    -oStrictHostKeyChecking="$SFTP_STRICT_HOSTKEY" \
    "$SFTP_USER@$SFTP_HOST" <<EOF_SFTP
put "$SPOOL_PDF" "$remote_tmp"
rename "$remote_tmp" "$remote_final"
EOF_SFTP

  log "INFO" "Datei per SFTP nach $SFTP_USER@$SFTP_HOST:$remote_final übertragen"
}

finalize_local_copy() {
  if str_to_bool "$KEEP_LOCAL_COPY"; then
    mv -f "$SPOOL_PDF" "$ARCHIVE_DIR/${base_name}.pdf"
  else
    rm -f "$SPOOL_PDF"
  fi
}

main() {
  load_config

  mkdir -p "$(dirname "${LOCK_FILE:-/var/lib/scan-to-paperless/scan-to-paperless.lock}")"
  exec 9>"${LOCK_FILE:-/var/lib/scan-to-paperless/scan-to-paperless.lock}"
  flock -n 9 || die "Ein anderer Scanlauf ist bereits aktiv"

  validate_config
  check_dependencies
  check_scanbd_action
  detect_device
  prepare_paths
  perform_scan
  remove_blank_pages_if_enabled
  rotate_final_pdf_if_enabled
  reverse_page_order_if_enabled

  install -m 0640 "$FINAL_PDF" "$SPOOL_PDF"

  case "${UPLOAD_METHOD,,}" in
    filesystem)
      deliver_filesystem
      ;;
    sftp)
      deliver_sftp
      ;;
  esac

  finalize_local_copy
  log "INFO" "Workflow erfolgreich abgeschlossen"
}

main "$@"
