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
  : "${STATE_DIR:=/var/lib/scan-to-paperless}"
  : "${LOCK_FILE:=$STATE_DIR/scan-to-paperless.lock}"
  : "${WORKER_LOCK_FILE:=$STATE_DIR/scan-to-paperless-worker.lock}"
  : "${INCOMING_DIR:=$STATE_DIR/incoming}"
  : "${QUEUE_DIR:=$STATE_DIR/queue}"
  : "${PROCESSING_DIR:=$STATE_DIR/processing}"
  : "${FAILED_DIR:=$STATE_DIR/failed}"
  : "${SPOOL_DIR:=$STATE_DIR/spool}"
  : "${ARCHIVE_DIR:=$STATE_DIR/archive}"
  : "${KEEP_LOCAL_COPY:=false}"
  : "${FILE_PREFIX:=scan}"
  : "${MAX_RETRIES:=3}"
  : "${RETRY_DELAY_MINUTES:=5}"
  : "${WORKER_IDLE_SECONDS:=5}"
  : "${STATUS_LIST_LIMIT:=5}"

  : "${SCAN_DEVICE:=}"
  : "${SCAN_SOURCE:=ADF Duplex}"
  : "${SCAN_MODE:=Gray}"
  : "${SCAN_RESOLUTION:=300}"
  : "${SCAN_FORMAT:=tiff}"
  : "${SCAN_PAGE_WIDTH:=210}"
  : "${SCAN_PAGE_HEIGHT:=297}"
  : "${SCAN_EXTRA_OPTS:=}"
  : "${REMOVE_BLANK_PAGES:=false}"
  : "${BLANK_THRESHOLD:=0.0012}"
  : "${MIN_PAGES_TO_FILTER:=2}"
  : "${PDF_ROTATION:=0}"
  : "${REVERSE_PAGE_ORDER:=false}"
  : "${EXPECTED_SCANBD_ACTION_REGEX:=^scan$}"

  : "${UPLOAD_METHOD:=filesystem}"
  : "${TARGET_DIR:=/mnt/paperless-consume}"
  : "${TARGET_SUBDIR:=}"
  : "${AUTO_CREATE_TARGET_DIR:=false}"
  : "${REQUIRE_TARGET_MOUNTPOINT:=}"
  : "${SFTP_HOST:=}"
  : "${SFTP_PORT:=22}"
  : "${SFTP_USER:=}"
  : "${SFTP_REMOTE_DIR:=}"
  : "${SFTP_IDENTITY_FILE:=/root/.ssh/paperless_scan}"
  : "${SFTP_STRICT_HOSTKEY:=accept-new}"
  : "${SFTP_CREATE_REMOTE_DIR:=false}"

  : "${PROFILE_FROM_SCANBD_FUNCTION:=true}"
  : "${PROFILE_DEFAULT_KEY:=1}"
  : "${FUNCTION_C_VALUES:=10 C c}"

  : "${EMBED_PROFILE_TEXT_LAYER:=false}"
  : "${INVISIBLE_TEXT_PREFIX:=paperless-skip-ocr}"
  : "${INVISIBLE_TEXT_TEMPLATE:=}"
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
  [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] || die "MAX_RETRIES muss numerisch sein"
  [[ "$RETRY_DELAY_MINUTES" =~ ^[0-9]+$ ]] || die "RETRY_DELAY_MINUTES muss numerisch sein"
  [[ "$WORKER_IDLE_SECONDS" =~ ^[0-9]+$ ]] || die "WORKER_IDLE_SECONDS muss numerisch sein"
  [[ "$STATUS_LIST_LIMIT" =~ ^[0-9]+$ ]] || die "STATUS_LIST_LIMIT muss numerisch sein"

  case "${PDF_ROTATION}" in
    0|90|180|270) ;;
    *) die "PDF_ROTATION muss 0, 90, 180 oder 270 sein" ;;
  esac

  str_to_bool "$REMOVE_BLANK_PAGES" || true
  str_to_bool "$AUTO_CREATE_TARGET_DIR" || true
  str_to_bool "$KEEP_LOCAL_COPY" || true
  str_to_bool "$SFTP_CREATE_REMOTE_DIR" || true
  str_to_bool "$REVERSE_PAGE_ORDER" || true
  str_to_bool "$PROFILE_FROM_SCANBD_FUNCTION" || true
  str_to_bool "$EMBED_PROFILE_TEXT_LAYER" || true

  if [[ "${UPLOAD_METHOD,,}" == "filesystem" ]]; then
    [[ -n "$TARGET_DIR" ]] || die "TARGET_DIR fehlt"
  else
    [[ -n "$SFTP_HOST" ]] || die "SFTP_HOST fehlt"
    [[ -n "$SFTP_USER" ]] || die "SFTP_USER fehlt"
    [[ -n "$SFTP_REMOTE_DIR" ]] || die "SFTP_REMOTE_DIR fehlt"
    [[ -r "$SFTP_IDENTITY_FILE" ]] || die "SFTP_IDENTITY_FILE nicht lesbar: $SFTP_IDENTITY_FILE"
  fi
}

check_common_dependencies() {
  require_cmd flock
  require_cmd logger
  require_cmd install
  require_cmd mv
  require_cmd cp
  require_cmd rm
  require_cmd awk
  require_cmd hostname
  require_cmd mktemp
  require_cmd date
  require_cmd find
  require_cmd sort
  require_cmd python3
}

check_enqueue_dependencies() {
  check_common_dependencies
  require_cmd scanimage
}

check_worker_dependencies() {
  check_common_dependencies
  require_cmd img2pdf
  require_cmd gs
  require_cmd qpdf

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

init_runtime() {
  host_short="$(hostname -s 2>/dev/null || hostname)"
}

ensure_state_dirs() {
  mkdir -p "$STATE_DIR" "$INCOMING_DIR" "$QUEUE_DIR" "$PROCESSING_DIR" "$FAILED_DIR" "$SPOOL_DIR"
  if str_to_bool "$KEEP_LOCAL_COPY"; then
    mkdir -p "$ARCHIVE_DIR"
  fi
}

normalize_profile_key() {
  local raw="$1"
  local token

  for token in $FUNCTION_C_VALUES; do
    if [[ "$raw" == "$token" ]]; then
      printf 'C\n'
      return
    fi
  done

  printf '%s\n' "$raw"
}

get_profile_setting() {
  local field="$1"
  local var="PROFILE_${PROFILE_KEY}_${field}"
  printf '%s' "${!var-}"
}

apply_profile_overrides() {
  local requested profile_label value

  if str_to_bool "$PROFILE_FROM_SCANBD_FUNCTION"; then
    requested="${SCAN_PROFILE_OVERRIDE:-${SCANBD_FUNCTION:-$PROFILE_DEFAULT_KEY}}"
  else
    requested="${SCAN_PROFILE_OVERRIDE:-$PROFILE_DEFAULT_KEY}"
  fi

  PROFILE_KEY="$(normalize_profile_key "$requested")"
  [[ -n "$PROFILE_KEY" ]] || PROFILE_KEY="$PROFILE_DEFAULT_KEY"
  PROFILE_KEY="$(printf '%s' "$PROFILE_KEY" | tr -cd 'A-Za-z0-9_')"
  [[ -n "$PROFILE_KEY" ]] || PROFILE_KEY="$PROFILE_DEFAULT_KEY"

  profile_label="$(get_profile_setting LABEL)"
  PROFILE_LABEL="${profile_label:-Profil $PROFILE_KEY}"

  value="$(get_profile_setting SOURCE)"; [[ -n "$value" ]] && SCAN_SOURCE="$value"
  value="$(get_profile_setting MODE)"; [[ -n "$value" ]] && SCAN_MODE="$value"
  value="$(get_profile_setting RESOLUTION)"; [[ -n "$value" ]] && SCAN_RESOLUTION="$value"
  value="$(get_profile_setting PAGE_WIDTH)"; [[ -n "$value" ]] && SCAN_PAGE_WIDTH="$value"
  value="$(get_profile_setting PAGE_HEIGHT)"; [[ -n "$value" ]] && SCAN_PAGE_HEIGHT="$value"
  value="$(get_profile_setting EXTRA_OPTS)"; [[ -n "$value" ]] && SCAN_EXTRA_OPTS="$value"
  value="$(get_profile_setting TARGET_SUBDIR)"; [[ -n "$value" ]] && TARGET_SUBDIR="$value"
  value="$(get_profile_setting REMOVE_BLANK_PAGES)"; [[ -n "$value" ]] && REMOVE_BLANK_PAGES="$value"
  value="$(get_profile_setting PDF_ROTATION)"; [[ -n "$value" ]] && PDF_ROTATION="$value"
  value="$(get_profile_setting REVERSE_PAGE_ORDER)"; [[ -n "$value" ]] && REVERSE_PAGE_ORDER="$value"
  value="$(get_profile_setting EMBED_TEXT_LAYER)"; [[ -n "$value" ]] && EMBED_PROFILE_TEXT_LAYER="$value"

  log "INFO" "Ausgewähltes Profil: key='$PROFILE_KEY' label='$PROFILE_LABEL' function='${SCANBD_FUNCTION:-}' source='$SCAN_SOURCE' mode='$SCAN_MODE' dpi='$SCAN_RESOLUTION'"
}

detect_device() {
  if [[ -n "$SCAN_DEVICE" ]]; then
    DEVICE="$SCAN_DEVICE"
    return
  fi

  DEVICE="$(scanimage -L 2>/dev/null | awk -F"'" '/device `/{print $2; exit}')"
  [[ -n "$DEVICE" ]] || die "Kein Scanner gefunden (scanimage -L)."
}

check_scanbd_action() {
  if [[ -n "${SCANBD_ACTION:-}" ]]; then
    if ! [[ "$SCANBD_ACTION" =~ $EXPECTED_SCANBD_ACTION_REGEX ]]; then
      die "Unerwartete scanbd-Aktion: '$SCANBD_ACTION' passt nicht auf $EXPECTED_SCANBD_ACTION_REGEX"
    fi
  fi
}

create_job_id() {
  printf 'job-%s-%05d-%04d\n' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
}

write_env_var() {
  local file="$1"
  local key="$2"
  local value="${3-}"
  printf '%s=%q\n' "$key" "$value" >>"$file"
}

save_job_metadata() {
  JOB_METADATA_FILE="$JOB_DIR/job.env"
  : >"$JOB_METADATA_FILE"

  write_env_var "$JOB_METADATA_FILE" JOB_ID "$JOB_ID"
  write_env_var "$JOB_METADATA_FILE" JOB_CREATED_EPOCH "$JOB_CREATED_EPOCH"
  write_env_var "$JOB_METADATA_FILE" BASE_NAME "$BASE_NAME"
  write_env_var "$JOB_METADATA_FILE" HOST_SHORT "$host_short"
  write_env_var "$JOB_METADATA_FILE" PROFILE_KEY "$PROFILE_KEY"
  write_env_var "$JOB_METADATA_FILE" PROFILE_LABEL "$PROFILE_LABEL"
  write_env_var "$JOB_METADATA_FILE" SCANBD_FUNCTION "${SCANBD_FUNCTION:-}"
  write_env_var "$JOB_METADATA_FILE" DEVICE "$DEVICE"
  write_env_var "$JOB_METADATA_FILE" SCAN_SOURCE "$SCAN_SOURCE"
  write_env_var "$JOB_METADATA_FILE" SCAN_MODE "$SCAN_MODE"
  write_env_var "$JOB_METADATA_FILE" SCAN_RESOLUTION "$SCAN_RESOLUTION"
  write_env_var "$JOB_METADATA_FILE" SCAN_FORMAT "$SCAN_FORMAT"
  write_env_var "$JOB_METADATA_FILE" SCAN_PAGE_WIDTH "$SCAN_PAGE_WIDTH"
  write_env_var "$JOB_METADATA_FILE" SCAN_PAGE_HEIGHT "$SCAN_PAGE_HEIGHT"
  write_env_var "$JOB_METADATA_FILE" SCAN_EXTRA_OPTS "$SCAN_EXTRA_OPTS"
  write_env_var "$JOB_METADATA_FILE" REMOVE_BLANK_PAGES "$REMOVE_BLANK_PAGES"
  write_env_var "$JOB_METADATA_FILE" BLANK_THRESHOLD "$BLANK_THRESHOLD"
  write_env_var "$JOB_METADATA_FILE" MIN_PAGES_TO_FILTER "$MIN_PAGES_TO_FILTER"
  write_env_var "$JOB_METADATA_FILE" PDF_ROTATION "$PDF_ROTATION"
  write_env_var "$JOB_METADATA_FILE" REVERSE_PAGE_ORDER "$REVERSE_PAGE_ORDER"
  write_env_var "$JOB_METADATA_FILE" EMBED_PROFILE_TEXT_LAYER "$EMBED_PROFILE_TEXT_LAYER"
  write_env_var "$JOB_METADATA_FILE" INVISIBLE_TEXT_PREFIX "$INVISIBLE_TEXT_PREFIX"
  write_env_var "$JOB_METADATA_FILE" INVISIBLE_TEXT_TEMPLATE "$INVISIBLE_TEXT_TEMPLATE"
  write_env_var "$JOB_METADATA_FILE" UPLOAD_METHOD "$UPLOAD_METHOD"
  write_env_var "$JOB_METADATA_FILE" TARGET_DIR "$TARGET_DIR"
  write_env_var "$JOB_METADATA_FILE" TARGET_SUBDIR "$TARGET_SUBDIR"
  write_env_var "$JOB_METADATA_FILE" AUTO_CREATE_TARGET_DIR "$AUTO_CREATE_TARGET_DIR"
  write_env_var "$JOB_METADATA_FILE" REQUIRE_TARGET_MOUNTPOINT "$REQUIRE_TARGET_MOUNTPOINT"
  write_env_var "$JOB_METADATA_FILE" SFTP_HOST "$SFTP_HOST"
  write_env_var "$JOB_METADATA_FILE" SFTP_PORT "$SFTP_PORT"
  write_env_var "$JOB_METADATA_FILE" SFTP_USER "$SFTP_USER"
  write_env_var "$JOB_METADATA_FILE" SFTP_REMOTE_DIR "$SFTP_REMOTE_DIR"
  write_env_var "$JOB_METADATA_FILE" SFTP_IDENTITY_FILE "$SFTP_IDENTITY_FILE"
  write_env_var "$JOB_METADATA_FILE" SFTP_STRICT_HOSTKEY "$SFTP_STRICT_HOSTKEY"
  write_env_var "$JOB_METADATA_FILE" SFTP_CREATE_REMOTE_DIR "$SFTP_CREATE_REMOTE_DIR"
}

save_job_state() {
  local state_file="$JOB_DIR/state.env"
  : >"$state_file"
  write_env_var "$state_file" ATTEMPT_COUNT "${ATTEMPT_COUNT:-0}"
  write_env_var "$state_file" NEXT_RETRY_EPOCH "${NEXT_RETRY_EPOCH:-0}"
  write_env_var "$state_file" LAST_ERROR "${LAST_ERROR:-}"
  write_env_var "$state_file" LAST_ERROR_EPOCH "${LAST_ERROR_EPOCH:-0}"
}

load_job() {
  JOB_DIR="$1"
  JOB_METADATA_FILE="$JOB_DIR/job.env"
  JOB_STATE_FILE="$JOB_DIR/state.env"
  [[ -r "$JOB_METADATA_FILE" ]] || die "Job-Metadaten fehlen: $JOB_METADATA_FILE"
  # shellcheck disable=SC1090
  source "$JOB_METADATA_FILE"

  ATTEMPT_COUNT=0
  NEXT_RETRY_EPOCH=0
  LAST_ERROR=""
  LAST_ERROR_EPOCH=0
  if [[ -r "$JOB_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$JOB_STATE_FILE"
  fi
}

collect_job_pages() {
  shopt -s nullglob
  PAGES=("$JOB_DIR"/pages/page-*.tif)
  shopt -u nullglob
  (( ${#PAGES[@]} > 0 )) || die "Job enthält keine Seiten: $JOB_DIR"
}

prepare_job_workdir() {
  WORKDIR="$(mktemp -d /tmp/scan-to-paperless.XXXXXX)"
  RAW_PDF="$WORKDIR/raw.pdf"
  FINAL_PDF="$WORKDIR/final.pdf"
  SPOOL_PDF="$SPOOL_DIR/${BASE_NAME}.pdf"
}

perform_scan_to_job() {
  local -a extra_opts=()
  local scan_rc=0

  if [[ -n "$SCAN_EXTRA_OPTS" ]]; then
    # Bewusst shell-artiges Splitting für einfache Konfiguration.
    # shellcheck disable=SC2206
    extra_opts=( $SCAN_EXTRA_OPTS )
  fi

  mkdir -p "$JOB_DIR/pages"

  log "INFO" "Starte Scan: device='$DEVICE' source='$SCAN_SOURCE' mode='$SCAN_MODE' dpi='$SCAN_RESOLUTION' width='${SCAN_PAGE_WIDTH}mm' height='${SCAN_PAGE_HEIGHT}mm'"

  if scanimage \
    -d "$DEVICE" \
    --source "$SCAN_SOURCE" \
    --mode "$SCAN_MODE" \
    --resolution "$SCAN_RESOLUTION" \
    --page-width "$SCAN_PAGE_WIDTH" \
    --page-height "$SCAN_PAGE_HEIGHT" \
    --format="$SCAN_FORMAT" \
    --batch="$JOB_DIR/pages/page-%04d.tif" \
    "${extra_opts[@]}"; then
    scan_rc=0
  else
    scan_rc=$?
  fi

  shopt -s nullglob
  PAGES=("$JOB_DIR"/pages/page-*.tif)
  shopt -u nullglob

  if (( ${#PAGES[@]} == 0 )); then
    log "INFO" "Kein Scanmaterial erkannt; ADF offenbar leer."
    return 2
  fi

  (( scan_rc == 0 )) || die "scanimage fehlgeschlagen (Exit-Code $scan_rc), obwohl Seiten erzeugt wurden"
  return 0
}

build_raw_pdf_from_pages() {
  collect_job_pages
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
    0|"")
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
  if ! str_to_bool "$REVERSE_PAGE_ORDER"; then
    return
  fi

  local reversed_pdf="$WORKDIR/reversed.pdf"
  qpdf --empty --pages "$FINAL_PDF" z-1 -- "$reversed_pdf"
  mv -f "$reversed_pdf" "$FINAL_PDF"
  log "INFO" "PDF-Seitenreihenfolge umgekehrt"
}

build_invisible_text_payload() {
  local template function_value profile_text
  function_value="${SCANBD_FUNCTION:-$PROFILE_KEY}"

  if [[ -n "$INVISIBLE_TEXT_TEMPLATE" ]]; then
    template="$INVISIBLE_TEXT_TEMPLATE"
    template="${template//\{PROFILE_KEY\}/$PROFILE_KEY}"
    template="${template//\{PROFILE_LABEL\}/$PROFILE_LABEL}"
    template="${template//\{FUNCTION\}/$function_value}"
    template="${template//\{SOURCE\}/$SCAN_SOURCE}"
    template="${template//\{MODE\}/$SCAN_MODE}"
    template="${template//\{RESOLUTION\}/$SCAN_RESOLUTION}"
    template="${template//\{DEVICE\}/$DEVICE}"
    template="${template//\{HOST\}/$HOST_SHORT}"
    profile_text="$template"
  else
    profile_text="${INVISIBLE_TEXT_PREFIX} profile=${PROFILE_KEY} label=${PROFILE_LABEL} function=${function_value} source=${SCAN_SOURCE} mode=${SCAN_MODE} dpi=${SCAN_RESOLUTION} scanner=${DEVICE} host=${HOST_SHORT}"
  fi

  printf '%s\n' "$profile_text"
}

create_invisible_text_overlay_pdf() {
  local overlay_pdf="$1"
  local text_payload="$2"

  python3 - "$SCAN_PAGE_WIDTH" "$SCAN_PAGE_HEIGHT" "$text_payload" "$overlay_pdf" <<'PY'
import sys
from pathlib import Path

width_mm = float(sys.argv[1])
height_mm = float(sys.argv[2])
text = sys.argv[3]
outfile = Path(sys.argv[4])

width_pt = width_mm * 72.0 / 25.4
height_pt = height_mm * 72.0 / 25.4

text = ''.join(ch if 32 <= ord(ch) <= 126 else ' ' for ch in text)

def esc(s: str) -> str:
    return s.replace('\\', r'\\').replace('(', r'\(').replace(')', r'\)')

content = (
    'BT\n'
    '/F1 6 Tf\n'
    '1 0 0 1 12 12 Tm\n'
    '3 Tr\n'
    f'({esc(text)}) Tj\n'
    'ET\n'
)
content_bytes = content.encode('ascii')

objects = [
    b'<< /Type /Catalog /Pages 2 0 R >>',
    b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width_pt:.2f} {height_pt:.2f}] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'.encode('ascii'),
    b'<< /Length ' + str(len(content_bytes)).encode('ascii') + b' >>\nstream\n' + content_bytes + b'endstream',
    b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
]

pdf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
offsets = [0]
for i, obj in enumerate(objects, start=1):
    offsets.append(len(pdf))
    pdf.extend(f'{i} 0 obj\n'.encode('ascii'))
    pdf.extend(obj)
    pdf.extend(b'\nendobj\n')

xref_offset = len(pdf)
pdf.extend(f'xref\n0 {len(objects)+1}\n'.encode('ascii'))
pdf.extend(b'0000000000 65535 f \n')
for off in offsets[1:]:
    pdf.extend(f'{off:010d} 00000 n \n'.encode('ascii'))
pdf.extend(
    f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n'.encode('ascii')
)

outfile.write_bytes(pdf)
PY
}

embed_invisible_text_layer_if_enabled() {
  local payload overlay_pdf with_text_pdf

  if ! str_to_bool "$EMBED_PROFILE_TEXT_LAYER"; then
    return
  fi

  payload="$(build_invisible_text_payload)"
  overlay_pdf="$WORKDIR/invisible-text-overlay.pdf"
  with_text_pdf="$WORKDIR/with-text.pdf"

  create_invisible_text_overlay_pdf "$overlay_pdf" "$payload"
  qpdf "$FINAL_PDF" --overlay "$overlay_pdf" --from= --repeat=1 -- "$with_text_pdf"
  mv -f "$with_text_pdf" "$FINAL_PDF"
  log "INFO" "Unsichtbare Textschicht eingebettet: '$payload'"
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

  remote_tmp="$TARGET_DIR_EFFECTIVE/.${BASE_NAME}.pdf.part"
  remote_final="$TARGET_DIR_EFFECTIVE/${BASE_NAME}.pdf"

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
  remote_tmp="$remote_dir/.${BASE_NAME}.pdf.part"
  remote_final="$remote_dir/${BASE_NAME}.pdf"

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

deliver_final_pdf() {
  install -m 0640 "$FINAL_PDF" "$SPOOL_PDF"

  case "${UPLOAD_METHOD,,}" in
    filesystem)
      deliver_filesystem
      ;;
    sftp)
      deliver_sftp
      ;;
  esac
}

finalize_local_copy() {
  if str_to_bool "$KEEP_LOCAL_COPY"; then
    install -m 0640 "$FINAL_PDF" "$ARCHIVE_DIR/${BASE_NAME}.pdf"
  fi
  rm -f "$SPOOL_PDF"
}

cleanup_workdir() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}

load_job_processing_context() {
  load_job "$1"
  collect_job_pages
  prepare_job_workdir
}

process_loaded_job() {
  build_raw_pdf_from_pages
  remove_blank_pages_if_enabled
  rotate_final_pdf_if_enabled
  reverse_page_order_if_enabled
  embed_invisible_text_layer_if_enabled
  deliver_final_pdf
  finalize_local_copy
}

set_job_error() {
  local message="$1"
  ATTEMPT_COUNT=$(( ATTEMPT_COUNT + 1 ))
  LAST_ERROR="$message"
  LAST_ERROR_EPOCH="$(date +%s)"
  if (( ATTEMPT_COUNT >= MAX_RETRIES )); then
    NEXT_RETRY_EPOCH=0
  else
    NEXT_RETRY_EPOCH=$(( LAST_ERROR_EPOCH + RETRY_DELAY_MINUTES * 60 ))
  fi
  save_job_state
}

job_current_error_message() {
  if [[ -n "${LAST_ERROR:-}" ]]; then
    printf '%s\n' "$LAST_ERROR"
  else
    printf 'unbekannter Fehler\n'
  fi
}

job_is_due() {
  local now="$1"
  load_job "$2"
  [[ "${NEXT_RETRY_EPOCH:-0}" =~ ^[0-9]+$ ]] || NEXT_RETRY_EPOCH=0
  (( NEXT_RETRY_EPOCH <= now ))
}

select_next_job() {
  local now="$1"
  local dir

  shopt -s nullglob
  for dir in "$QUEUE_DIR"/job-*; do
    [[ -d "$dir" ]] || continue
    if job_is_due "$now" "$dir"; then
      printf '%s\n' "$dir"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

count_job_dirs() {
  local dir="$1"
  local count=0
  local entry

  shopt -s nullglob
  for entry in "$dir"/job-*; do
    [[ -d "$entry" ]] && count=$(( count + 1 ))
  done
  shopt -u nullglob
  printf '%s\n' "$count"
}

format_age() {
  local since_epoch="$1"
  local now="$2"
  local age
  age=$(( now - since_epoch ))
  if (( age < 60 )); then
    printf '%ss' "$age"
  elif (( age < 3600 )); then
    printf '%sm' "$(( age / 60 ))"
  else
    printf '%sh' "$(( age / 3600 ))"
  fi
}

format_retry() {
  local next_epoch="$1"
  local now="$2"
  local diff

  if (( next_epoch <= now )); then
    printf 'now'
    return
  fi

  diff=$(( next_epoch - now ))
  if (( diff < 60 )); then
    printf 'in %ss' "$diff"
  else
    printf 'in %sm' "$(( diff / 60 ))"
  fi
}

print_job_listing() {
  local dir="$1"
  local label="$2"
  local limit="$3"
  local now="$4"
  local entry shown=0

  shopt -s nullglob
  for entry in "$dir"/job-*; do
    [[ -d "$entry" ]] || continue
    load_job "$entry"
    printf '%s %s profile=%s age=%s attempts=%s' \
      "$label" \
      "$JOB_ID" \
      "$PROFILE_KEY" \
      "$(format_age "$JOB_CREATED_EPOCH" "$now")" \
      "$ATTEMPT_COUNT"
    if (( NEXT_RETRY_EPOCH > now )); then
      printf ' retry=%s' "$(format_retry "$NEXT_RETRY_EPOCH" "$now")"
    fi
    if [[ -n "$LAST_ERROR" ]]; then
      printf ' error=%s' "$LAST_ERROR"
    fi
    printf '\n'
    shown=$(( shown + 1 ))
    (( shown >= limit )) && break
  done
  shopt -u nullglob
}

cmd_enqueue() {
  local scan_rc=0

  load_config
  validate_config
  check_enqueue_dependencies
  init_runtime
  ensure_state_dirs
  check_scanbd_action
  apply_profile_overrides

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Ein anderer physischer Scanlauf ist bereits aktiv"

  detect_device

  JOB_ID="$(create_job_id)"
  JOB_CREATED_EPOCH="$(date +%s)"
  BASE_NAME="${FILE_PREFIX}_${host_short}_$(date +'%Y%m%d-%H%M%S')_${PROFILE_KEY}_${JOB_ID}"
  JOB_DIR="$INCOMING_DIR/$JOB_ID"

  mkdir -p "$JOB_DIR"

  if perform_scan_to_job; then
    scan_rc=0
  else
    scan_rc=$?
    if (( scan_rc == 2 )); then
      rm -rf "$JOB_DIR"
      log "INFO" "Leerer ADF; kein Job angelegt."
      return 0
    fi
    rm -rf "$JOB_DIR"
    return "$scan_rc"
  fi

  save_job_metadata
  ATTEMPT_COUNT=0
  NEXT_RETRY_EPOCH=0
  LAST_ERROR=""
  LAST_ERROR_EPOCH=0
  save_job_state

  mv "$JOB_DIR" "$QUEUE_DIR/$JOB_ID"
  log "INFO" "Scan erfolgreich in Warteschlange gelegt: job='$JOB_ID' pages='${#PAGES[@]}' profile='$PROFILE_KEY'"
}

process_next_job() {
  local now queue_job processing_job rc

  now="$(date +%s)"
  if ! queue_job="$(select_next_job "$now")"; then
    return 1
  fi

  processing_job="$PROCESSING_DIR/$(basename "$queue_job")"
  mv "$queue_job" "$processing_job"

  if (
    load_config
    validate_config
    check_worker_dependencies
    ensure_state_dirs
    load_job_processing_context "$processing_job"
    trap cleanup_workdir EXIT
    process_loaded_job
  ); then
    rm -rf "$processing_job"
    log "INFO" "Job erfolgreich verarbeitet: $(basename "$processing_job")"
    return 0
  else
    rc=$?
  fi
  load_job "$processing_job"
  set_job_error "Worker-Fehler (Exit-Code $rc)"
  if (( ATTEMPT_COUNT >= MAX_RETRIES )); then
    mv "$processing_job" "$FAILED_DIR/$(basename "$processing_job")"
    log "ERROR" "Job endgültig fehlgeschlagen: $JOB_ID nach $ATTEMPT_COUNT Versuchen"
  else
    mv "$processing_job" "$QUEUE_DIR/$(basename "$processing_job")"
    log "WARN" "Job fehlgeschlagen, neuer Versuch geplant: $JOB_ID retry=$(format_retry "$NEXT_RETRY_EPOCH" "$(date +%s)")"
  fi
  return 0
}

cmd_worker() {
  local mode="${1:-}"

  load_config
  validate_config
  check_worker_dependencies
  init_runtime
  ensure_state_dirs

  mkdir -p "$(dirname "$WORKER_LOCK_FILE")"
  exec 8>"$WORKER_LOCK_FILE"
  flock -n 8 || die "Ein anderer Worker läuft bereits"

  while true; do
    if process_next_job; then
      continue
    fi
    if [[ "$mode" == "--once" ]]; then
      break
    fi
    sleep "$WORKER_IDLE_SECONDS"
  done
}

cmd_status() {
  local now queued processing failed

  load_config
  validate_config
  init_runtime
  ensure_state_dirs

  now="$(date +%s)"
  queued="$(count_job_dirs "$QUEUE_DIR")"
  processing="$(count_job_dirs "$PROCESSING_DIR")"
  failed="$(count_job_dirs "$FAILED_DIR")"

  printf 'queue=%s processing=%s failed=%s\n' "$queued" "$processing" "$failed"
  print_job_listing "$PROCESSING_DIR" "processing" "$STATUS_LIST_LIMIT" "$now"
  print_job_listing "$QUEUE_DIR" "queued" "$STATUS_LIST_LIMIT" "$now"
  print_job_listing "$FAILED_DIR" "failed" "$STATUS_LIST_LIMIT" "$now"
}

usage() {
  cat <<'EOF'
Usage:
  scan-to-paperless.sh enqueue
  scan-to-paperless.sh worker [--once]
  scan-to-paperless.sh status
EOF
}

main() {
  local command="${1:-enqueue}"
  shift || true

  case "$command" in
    enqueue)
      cmd_enqueue "$@"
      ;;
    worker)
      cmd_worker "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
