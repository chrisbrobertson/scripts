#!/usr/bin/env bash
# Install and validate Poolside Laguna S 2.1 on a 128 GB Apple Silicon Mac.
#
# Default behavior:
#   - checks hardware and disk space
#   - installs Ollama, Laguna S 2.1, Poolside Agent CLI, uv, LiteLLM,
#     Claude Code, and Codex CLI when missing
#   - runs Ollama and LiteLLM as per-user launchd services
#   - creates explicit local wrappers: pool-poolside, claude-poolside,
#     and codex-poolside
#   - executes protocol and end-to-end harness tests
#
# Optional persistent repointing:
#   --repoint-opus   Make Claude Code's Opus selection use the local model.
#   --repoint-codex  Make ordinary Codex CLI invocations use the local model.
#   --repoint-all    Apply both persistent repoints.
#   --restore-harnesses
#                    Revert only the persistent Claude/Codex repoints.
#
# The Poolside installer has an EULA. Pass --accept-poolside-eula only after
# reviewing it; otherwise its installer remains interactive.

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly REQUIRED_RAM_BYTES=$((128 * 1024 * 1024 * 1024))
readonly MIN_FREE_KIB=$((90 * 1024 * 1024))
readonly MODEL_BASE="laguna-s-2.1:latest"
readonly MODEL_LOCAL="poolside-s2.1-local:latest"
readonly LITELLM_MODEL="poolside-s2.1"
readonly OLLAMA_URL="http://127.0.0.1:11434"
readonly LITELLM_URL="http://127.0.0.1:4000"
readonly DEFAULT_CONTEXT=32768
readonly INFERENCE_TIMEOUT=1800
readonly MIN_CODEX_VERSION="0.145.0"

CONFIG_DIR="${HOME}/.config/poolside-s21"
STATE_DIR="${HOME}/.local/share/poolside-s21"
BIN_DIR="${HOME}/.local/bin"
LOG_DIR="${HOME}/Library/Logs/poolside-s21"
LAUNCH_DIR="${HOME}/Library/LaunchAgents"
RUNTIME_ENV="${CONFIG_DIR}/runtime.env"
LITELLM_CONFIG="${CONFIG_DIR}/litellm.yaml"
LITELLM_VENV="${STATE_DIR}/litellm-venv"
MODELFILE="${CONFIG_DIR}/Modelfile"
HELPER_PY="${STATE_DIR}/config_helper.py"
TEST_REPORT="${LOG_DIR}/last-test-report.txt"
OLLAMA_PLIST="${LAUNCH_DIR}/ai.poolside.s21.ollama.plist"
LITELLM_PLIST="${LAUNCH_DIR}/ai.poolside.s21.litellm.plist"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CLAUDE_LOCAL_SETTINGS="${CONFIG_DIR}/claude-local-settings.json"
CLAUDE_STATE="${STATE_DIR}/claude-repoint-state.json"
CODEX_CONFIG_DIR="${HOME}/.codex"
CODEX_CONFIG="${CODEX_CONFIG_DIR}/config.toml"
CODEX_PROFILE="${CODEX_CONFIG_DIR}/poolside-s21.config.toml"
ZPROFILE="${HOME}/.zprofile"

ACCEPT_EULA=0
REPOINT_OPUS=0
REPOINT_CODEX=0
RESTORE_HARNESSES=0
SKIP_TESTS=0
SKIP_PULL=0
TEST_ONLY=0
UPGRADE_TOOLS=0
CONTEXT_LENGTH="${DEFAULT_CONTEXT}"

UV_BIN=""
OLLAMA_BIN=""
LITELLM_BIN=""
POOL_BIN=""
CLAUDE_BIN=""
CODEX_BIN=""
LITELLM_MASTER_KEY=""
OLLAMA_UPGRADED=0

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --accept-poolside-eula  Non-interactively accept the Poolside Agent CLI EULA.
  --repoint-opus          Persistently route Claude Code's Opus selection locally.
  --repoint-codex         Persistently route ordinary Codex CLI use locally.
  --repoint-all           Equivalent to --repoint-opus --repoint-codex.
  --restore-harnesses     Revert persistent Claude/Codex repointing and exit.
  --context N             Set the local Ollama context (default: 32768).
                          On exactly 128 GB, 32768 is the conservative choice.
  --upgrade-tools         Upgrade already-installed CLI tools where supported.
  --skip-pull             Do not download or create the model (debugging only).
  --skip-tests            Do not run live validation (not recommended).
  --test-only             Skip installation and run the full validation suite.
  -h, --help              Show this help.

Examples:
  ./${SCRIPT_NAME} --accept-poolside-eula
  ./${SCRIPT_NAME} --accept-poolside-eula --repoint-all
  ./${SCRIPT_NAME} --test-only
  ./${SCRIPT_NAME} --restore-harnesses
EOF
}

log() {
  printf '[poolside-s21] %s\n' "$*"
}

warn() {
  printf '[poolside-s21] WARNING: %s\n' "$*" >&2
}

fatal() {
  printf '[poolside-s21] ERROR: %s\n' "$*" >&2
  exit 1
}

quote_xml() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --accept-poolside-eula)
        ACCEPT_EULA=1
        ;;
      --repoint-opus)
        REPOINT_OPUS=1
        ;;
      --repoint-codex)
        REPOINT_CODEX=1
        ;;
      --repoint-all)
        REPOINT_OPUS=1
        REPOINT_CODEX=1
        ;;
      --restore-harnesses)
        RESTORE_HARNESSES=1
        ;;
      --context)
        shift
        [ "$#" -gt 0 ] || fatal "--context requires an integer."
        CONTEXT_LENGTH="$1"
        ;;
      --upgrade-tools)
        UPGRADE_TOOLS=1
        ;;
      --skip-pull)
        SKIP_PULL=1
        ;;
      --skip-tests)
        SKIP_TESTS=1
        ;;
      --test-only)
        TEST_ONLY=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "Unknown option: $1 (use --help)"
        ;;
    esac
    shift
  done

  case "${CONTEXT_LENGTH}" in
    ''|*[!0-9]*) fatal "--context must be a positive integer." ;;
  esac
  [ "${CONTEXT_LENGTH}" -ge 8192 ] || fatal "--context must be at least 8192."
  if [ "${CONTEXT_LENGTH}" -gt 65536 ]; then
    warn "A context above 65536 is not recommended on a 128 GB Mac."
  fi
  if [ "${TEST_ONLY}" -eq 1 ] && [ "${SKIP_TESTS}" -eq 1 ]; then
    fatal "--test-only and --skip-tests are mutually exclusive."
  fi
}

ensure_dirs() {
  mkdir -p "${CONFIG_DIR}" "${STATE_DIR}" "${BIN_DIR}" "${LOG_DIR}" \
    "${LAUNCH_DIR}" "${CODEX_CONFIG_DIR}" "$(dirname "${CLAUDE_SETTINGS}")"
  chmod 700 "${CONFIG_DIR}" "${STATE_DIR}"
}

check_platform() {
  [ "$(uname -s)" = "Darwin" ] || fatal "This installer supports macOS only."

  local arm64_capable
  arm64_capable="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || printf '0')"
  [ "${arm64_capable}" = "1" ] || fatal "Laguna S 2.1 requires an Apple Silicon Mac for this setup."

  if [ "$(uname -m)" != "arm64" ]; then
    fatal "This shell is running under Rosetta. Open a native arm64 terminal and rerun."
  fi

  local os_major
  os_major="$(/usr/bin/sw_vers -productVersion | awk -F. '{print $1}')"
  case "${os_major}" in
    ''|*[!0-9]*) fatal "Could not determine the macOS version." ;;
  esac
  [ "${os_major}" -ge 14 ] || fatal "Current Ollama for macOS requires macOS 14 (Sonoma) or newer."

  local ram_bytes ram_gib
  ram_bytes="$(/usr/sbin/sysctl -n hw.memsize)"
  ram_gib=$((ram_bytes / 1024 / 1024 / 1024))
  if [ "${ram_bytes}" -lt "${REQUIRED_RAM_BYTES}" ]; then
    fatal "Detected ${ram_gib} GiB RAM; Laguna S 2.1 requires at least 128 GiB unified memory."
  fi
  log "Hardware check passed: Apple Silicon, macOS $(/usr/bin/sw_vers -productVersion), ${ram_gib} GiB RAM."
}

model_is_installed() {
  [ -n "${OLLAMA_BIN}" ] || return 1
  "${OLLAMA_BIN}" list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fqx "${MODEL_BASE}"
}

check_disk_for_pull() {
  if model_is_installed; then
    log "Base model is already present; skipping pre-download disk check."
    return 0
  fi

  local free_kib free_gib
  free_kib="$(df -Pk "${HOME}" | awk 'NR == 2 {print $4}')"
  free_gib=$((free_kib / 1024 / 1024))
  if [ "${free_kib}" -lt "${MIN_FREE_KIB}" ]; then
    fatal "Only ${free_gib} GiB is free on the home volume; reserve at least 90 GiB before pulling the 75 GB model."
  fi
  log "Disk check passed: ${free_gib} GiB available on the home volume."
}

remove_managed_block() {
  local file="$1" begin="$2" end="$3" tmp
  [ -f "${file}" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/poolside-s21.block.XXXXXX")"
  awk -v begin="${begin}" -v end="${end}" '
    $0 == begin {inside=1; next}
    $0 == end   {inside=0; next}
    !inside     {print}
  ' "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

append_managed_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  touch "${file}"
  remove_managed_block "${file}" "${begin}" "${end}"
  {
    printf '\n%s\n' "${begin}"
    printf '%s\n' "${content}"
    printf '%s\n' "${end}"
  } >> "${file}"
}

configure_path() {
  local begin='# >>> poolside-s21 PATH >>>'
  local end='# <<< poolside-s21 PATH <<<'
  append_managed_block "${ZPROFILE}" "${begin}" "${end}" 'export PATH="$HOME/.local/bin:$PATH"'
  export PATH="${BIN_DIR}:${PATH}"
  hash -r
}

find_executable() {
  local name="$1"
  shift
  local found candidate
  found="$(command -v "${name}" 2>/dev/null || true)"
  if [ -n "${found}" ] && [ -x "${found}" ]; then
    printf '%s\n' "${found}"
    return 0
  fi
  for candidate in "$@"; do
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

download_and_run() {
  local url="$1"
  shift
  local temp_script rc
  temp_script="$(mktemp "${TMPDIR:-/tmp}/poolside-s21.installer.XXXXXX")"
  /usr/bin/curl -fsSL "${url}" -o "${temp_script}"
  set +e
  /bin/bash "${temp_script}" "$@"
  rc=$?
  set -e
  rm -f "${temp_script}"
  return "${rc}"
}

install_uv() {
  UV_BIN="$(find_executable uv "${BIN_DIR}/uv" "${HOME}/.cargo/bin/uv" || true)"
  if [ -z "${UV_BIN}" ]; then
    log "Installing uv."
    download_and_run "https://astral.sh/uv/install.sh"
    hash -r
    UV_BIN="$(find_executable uv "${BIN_DIR}/uv" "${HOME}/.cargo/bin/uv" || true)"
  elif [ "${UPGRADE_TOOLS}" -eq 1 ]; then
    log "Updating uv."
    "${UV_BIN}" self update || warn "uv self-update failed; continuing with the installed version."
  fi
  [ -n "${UV_BIN}" ] || fatal "uv installation did not produce an executable."
  log "uv: $("${UV_BIN}" --version)"
}

fetch_latest_ollama_version() {
  /usr/bin/curl -fsSL --max-time 10 \
    "https://api.github.com/repos/ollama/ollama/releases/latest" 2>/dev/null \
    | grep '"tag_name"' \
    | sed 's/.*"v\([0-9][^"]*\)".*/\1/' \
    | head -n 1
}

install_ollama() {
  OLLAMA_BIN="$(find_executable ollama \
    "/Applications/Ollama.app/Contents/Resources/ollama" \
    "${HOME}/Applications/Ollama.app/Contents/Resources/ollama" || true)"

  local latest_version=""
  latest_version="$(fetch_latest_ollama_version || true)"

  if [ -z "${OLLAMA_BIN}" ]; then
    local version_hint=""
    [ -n "${latest_version}" ] && version_hint=" (latest: ${latest_version})"
    printf '[poolside-s21] Ollama is not installed%s. Install now? [y/N] ' "${version_hint}"
    local answer=""
    read -r answer </dev/tty || true
    case "${answer}" in
      [yY]|[yY][eE][sS]) ;;
      *) fatal "Ollama is required; aborting." ;;
    esac
    log "Installing Ollama from the official installer."
    download_and_run "https://ollama.com/install.sh"
    hash -r
    OLLAMA_BIN="$(find_executable ollama \
      "/Applications/Ollama.app/Contents/Resources/ollama" \
      "${HOME}/Applications/Ollama.app/Contents/Resources/ollama" || true)"
  elif [ "${UPGRADE_TOOLS}" -eq 1 ]; then
    log "Upgrading Ollama via the official installer."
    download_and_run "https://ollama.com/install.sh"
    hash -r
    OLLAMA_UPGRADED=1
    OLLAMA_BIN="$(find_executable ollama \
      "/Applications/Ollama.app/Contents/Resources/ollama" \
      "${HOME}/Applications/Ollama.app/Contents/Resources/ollama" || true)"
  else
    local current_version=""
    current_version="$("${OLLAMA_BIN}" --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
    if [ -n "${latest_version}" ] && [ -n "${current_version}" ] && \
       ! version_at_least "${current_version}" "${latest_version}"; then
      warn "Ollama ${current_version} is installed; latest is ${latest_version}. Pass --upgrade-tools to upgrade."
    fi
  fi

  [ -n "${OLLAMA_BIN}" ] || fatal "Ollama installation did not produce an executable."
  log "Ollama: $("${OLLAMA_BIN}" --version 2>&1 | head -n 1)"
}

install_litellm() {
  local python_bin="${LITELLM_VENV}/bin/python"
  if [ ! -x "${python_bin}" ]; then
    log "Creating a dedicated LiteLLM virtual environment."
    rm -rf "${LITELLM_VENV}"
    "${UV_BIN}" venv --python 3.12 "${LITELLM_VENV}"
  fi

  local install_args=(pip install --python "${python_bin}")
  if [ "${UPGRADE_TOOLS}" -eq 1 ]; then
    install_args+=(--upgrade)
  fi
  install_args+=('litellm[proxy]>=1.66.3')
  log "Ensuring a Codex- and Claude-compatible LiteLLM proxy is installed."
  "${UV_BIN}" "${install_args[@]}"

  LITELLM_BIN="${LITELLM_VENV}/bin/litellm"
  [ -x "${LITELLM_BIN}" ] || fatal "LiteLLM installation did not produce an executable."
  log "LiteLLM: $("${LITELLM_BIN}" --version 2>&1 | head -n 1)"
}

install_pool() {
  POOL_BIN="$(find_executable pool "${BIN_DIR}/pool" || true)"
  if [ -z "${POOL_BIN}" ]; then
    log "Installing Poolside Agent CLI."
    local temp_script
    temp_script="$(mktemp "${TMPDIR:-/tmp}/poolside-agent-installer.XXXXXX")"
    /usr/bin/curl -fsSL "https://downloads.poolside.ai/pool/install.sh" -o "${temp_script}"
    if [ "${ACCEPT_EULA}" -eq 1 ]; then
      POOL_INSTALL_ACCEPT_EULA=1 POOL_INSTALL_DIR="${BIN_DIR}" /bin/bash "${temp_script}"
    else
      POOL_INSTALL_DIR="${BIN_DIR}" /bin/bash "${temp_script}"
    fi
    rm -f "${temp_script}"
    hash -r
    POOL_BIN="$(find_executable pool "${BIN_DIR}/pool" || true)"
  elif [ "${UPGRADE_TOOLS}" -eq 1 ]; then
    log "Updating Poolside Agent CLI."
    "${POOL_BIN}" update || warn "Poolside Agent CLI update failed; continuing with the installed version."
  fi
  [ -n "${POOL_BIN}" ] || fatal "Poolside Agent CLI installation did not produce an executable."
  log "Poolside Agent CLI: $("${POOL_BIN}" --version 2>&1 | head -n 1)"
}

install_claude() {
  CLAUDE_BIN="$(find_executable claude "${BIN_DIR}/claude" "${HOME}/.claude/local/claude" || true)"
  if [ -z "${CLAUDE_BIN}" ]; then
    log "Installing Claude Code from Anthropic's native installer."
    download_and_run "https://claude.ai/install.sh"
    hash -r
    CLAUDE_BIN="$(find_executable claude "${BIN_DIR}/claude" "${HOME}/.claude/local/claude" || true)"
  elif [ "${UPGRADE_TOOLS}" -eq 1 ]; then
    log "Updating Claude Code."
    "${CLAUDE_BIN}" update || warn "Claude Code update failed; continuing with the installed version."
  fi
  [ -n "${CLAUDE_BIN}" ] || fatal "Claude Code installation did not produce an executable."
  log "Claude Code: $("${CLAUDE_BIN}" --version 2>&1 | head -n 1)"
}

version_at_least() {
  local current="${1%%-*}" required="${2%%-*}"
  local c1=0 c2=0 c3=0 r1=0 r2=0 r3=0
  IFS=. read -r c1 c2 c3 <<< "${current}"
  IFS=. read -r r1 r2 r3 <<< "${required}"
  c1="${c1:-0}"; c2="${c2:-0}"; c3="${c3:-0}"
  r1="${r1:-0}"; r2="${r2:-0}"; r3="${r3:-0}"
  [ "${c1}" -gt "${r1}" ] || {
    [ "${c1}" -eq "${r1}" ] && {
      [ "${c2}" -gt "${r2}" ] || {
        [ "${c2}" -eq "${r2}" ] && [ "${c3}" -ge "${r3}" ];
      };
    };
  }
}

install_codex() {
  CODEX_BIN="$(find_executable codex "${BIN_DIR}/codex" || true)"
  local current_version="" install_needed=0
  if [ -n "${CODEX_BIN}" ]; then
    current_version="$("${CODEX_BIN}" --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  fi

  if [ -z "${CODEX_BIN}" ] || [ -z "${current_version}" ]; then
    install_needed=1
  elif ! version_at_least "${current_version}" "${MIN_CODEX_VERSION}"; then
    log "Codex ${current_version} is too old for command-backed local-provider auth; ${MIN_CODEX_VERSION}+ is required."
    install_needed=1
  elif [ "${UPGRADE_TOOLS}" -eq 1 ]; then
    install_needed=1
  fi

  if [ "${install_needed}" -eq 1 ]; then
    log "Installing the current Codex CLI from OpenAI's native installer."
    CODEX_NON_INTERACTIVE=1 download_and_run "https://chatgpt.com/codex/install.sh"
    hash -r
    CODEX_BIN="$(find_executable codex "${BIN_DIR}/codex" || true)"
  fi
  [ -n "${CODEX_BIN}" ] || fatal "Codex CLI installation did not produce an executable."
  current_version="$("${CODEX_BIN}" --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  [ -n "${current_version}" ] || fatal "Could not determine the installed Codex CLI version."
  version_at_least "${current_version}" "${MIN_CODEX_VERSION}" || \
    fatal "Codex ${current_version} is installed, but ${MIN_CODEX_VERSION}+ is required."
  log "Codex CLI: $("${CODEX_BIN}" --version 2>&1 | head -n 1)"
}

load_or_create_key() {
  if [ -f "${RUNTIME_ENV}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV}"
    LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
  fi

  if [ -z "${LITELLM_MASTER_KEY}" ]; then
    LITELLM_MASTER_KEY="sk-local-$(/usr/bin/openssl rand -hex 24)"
    umask 077
    printf 'LITELLM_MASTER_KEY=%s\n' "${LITELLM_MASTER_KEY}" > "${RUNTIME_ENV}"
  fi
  chmod 600 "${RUNTIME_ENV}"
  export LITELLM_MASTER_KEY
}

write_runtime_config() {
  cat > "${MODELFILE}" <<EOF
FROM ${MODEL_BASE}
PARAMETER num_ctx ${CONTEXT_LENGTH}
EOF

  cat > "${LITELLM_CONFIG}" <<EOF
model_list:
  - model_name: ${LITELLM_MODEL}
    litellm_params:
      model: openai/${MODEL_LOCAL}
      api_base: ${OLLAMA_URL}/v1
      api_key: ollama
      timeout: ${INFERENCE_TIMEOUT}
      stream_timeout: ${INFERENCE_TIMEOUT}

litellm_settings:
  drop_params: true
  modify_params: true
  request_timeout: ${INFERENCE_TIMEOUT}
  set_verbose: false

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF

  cat > "${CLAUDE_LOCAL_SETTINGS}" <<EOF
{
  "model": "opus",
  "env": {
    "ANTHROPIC_BASE_URL": "${LITELLM_URL}",
    "ANTHROPIC_AUTH_TOKEN": "${LITELLM_MASTER_KEY}",
    "ANTHROPIC_API_KEY": "${LITELLM_MASTER_KEY}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${LITELLM_MODEL}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${LITELLM_MODEL}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${LITELLM_MODEL}",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "${LITELLM_MODEL}",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Poolside Laguna S 2.1 (local)",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Local Poolside model through LiteLLM and Ollama",
    "CLAUDE_CODE_USE_BEDROCK": "0",
    "CLAUDE_CODE_USE_VERTEX": "0",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1"
  }
}
EOF
  chmod 600 "${LITELLM_CONFIG}" "${MODELFILE}" "${CLAUDE_LOCAL_SETTINGS}"
}

write_ollama_launch_agent() {
  local ollama_script="${STATE_DIR}/serve-ollama.sh"
  cat > "${ollama_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_LOAD_TIMEOUT=20m
export OLLAMA_KEEP_ALIVE=30m
exec $(printf '%q' "${OLLAMA_BIN}") serve
EOF
  chmod 700 "${ollama_script}"

  local script_xml stdout_xml stderr_xml
  script_xml="$(quote_xml "${ollama_script}")"
  stdout_xml="$(quote_xml "${LOG_DIR}/ollama.log")"
  stderr_xml="$(quote_xml "${LOG_DIR}/ollama-error.log")"
  cat > "${OLLAMA_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.poolside.s21.ollama</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_xml}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${stdout_xml}</string>
  <key>StandardErrorPath</key><string>${stderr_xml}</string>
</dict>
</plist>
EOF
  chmod 600 "${OLLAMA_PLIST}"
  /usr/bin/plutil -lint "${OLLAMA_PLIST}" >/dev/null
}

write_litellm_launch_agent() {
  local litellm_script="${STATE_DIR}/serve-litellm.sh"
  cat > "${litellm_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. $(printf '%q' "${RUNTIME_ENV}")
export LITELLM_MASTER_KEY
exec $(printf '%q' "${LITELLM_BIN}") --config $(printf '%q' "${LITELLM_CONFIG}") --host 127.0.0.1 --port 4000
EOF
  chmod 700 "${litellm_script}"

  local script_xml stdout_xml stderr_xml
  script_xml="$(quote_xml "${litellm_script}")"
  stdout_xml="$(quote_xml "${LOG_DIR}/litellm.log")"
  stderr_xml="$(quote_xml "${LOG_DIR}/litellm-error.log")"
  cat > "${LITELLM_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.poolside.s21.litellm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_xml}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${stdout_xml}</string>
  <key>StandardErrorPath</key><string>${stderr_xml}</string>
</dict>
</plist>
EOF
  chmod 600 "${LITELLM_PLIST}"
  /usr/bin/plutil -lint "${LITELLM_PLIST}" >/dev/null
}

launch_agent() {
  local label="$1" plist="$2"
  local domain="gui/$(id -u)"
  /bin/launchctl bootout "${domain}" "${plist}" >/dev/null 2>&1 || true
  if ! /bin/launchctl bootstrap "${domain}" "${plist}"; then
    fatal "Could not load ${label} with launchd. Run this installer from a logged-in macOS user session."
  fi
  /bin/launchctl enable "${domain}/${label}" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "${domain}/${label}" >/dev/null 2>&1 || true
}

url_healthy() {
  local url="$1"
  /usr/bin/curl -fsS --connect-timeout 2 --max-time 5 "${url}" >/dev/null 2>&1
}

wait_for_url() {
  local name="$1" url="$2" attempts="${3:-60}" delay="${4:-2}"
  local i=1
  while [ "${i}" -le "${attempts}" ]; do
    if url_healthy "${url}"; then
      log "${name} is reachable."
      return 0
    fi
    sleep "${delay}"
    i=$((i + 1))
  done
  return 1
}

start_ollama() {
  if url_healthy "${OLLAMA_URL}/api/version"; then
    if [ "${OLLAMA_UPGRADED}" -eq 1 ]; then
      log "Ollama was just upgraded; restarting the running server."
      /bin/launchctl bootout "gui/$(id -u)" "${OLLAMA_PLIST}" >/dev/null 2>&1 || \
        pkill -x ollama >/dev/null 2>&1 || true
      sleep 2
    else
      log "An Ollama server is already listening on 127.0.0.1:11434; reusing it."
      return 0
    fi
  fi
  write_ollama_launch_agent
  log "Starting Ollama with launchd."
  launch_agent "ai.poolside.s21.ollama" "${OLLAMA_PLIST}"
  if ! wait_for_url "Ollama" "${OLLAMA_URL}/api/version" 90 2; then
    tail -n 80 "${LOG_DIR}/ollama-error.log" 2>/dev/null || true
    fatal "Ollama did not become healthy."
  fi
}

pull_and_create_model() {
  if [ "${SKIP_PULL}" -eq 1 ]; then
    warn "Skipping model pull and local context-tag creation."
    return 0
  fi

  if ! model_is_installed; then
    log "Pulling ${MODEL_BASE}."
    OLLAMA_LOAD_TIMEOUT=20m "${OLLAMA_BIN}" pull "${MODEL_BASE}"
  else
    log "${MODEL_BASE} is already installed."
  fi

  log "Creating/updating ${MODEL_LOCAL} with a ${CONTEXT_LENGTH}-token context."
  OLLAMA_LOAD_TIMEOUT=20m "${OLLAMA_BIN}" create "${MODEL_LOCAL}" -f "${MODELFILE}"
}

start_litellm() {
  write_litellm_launch_agent
  log "Starting LiteLLM with launchd."
  launch_agent "ai.poolside.s21.litellm" "${LITELLM_PLIST}"
  if ! wait_for_url "LiteLLM" "${LITELLM_URL}/health/liveliness" 90 2; then
    tail -n 120 "${LOG_DIR}/litellm-error.log" 2>/dev/null || true
    fatal "LiteLLM did not become healthy."
  fi
}

write_config_helper() {
  cat > "${HELPER_PY}" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

MISSING = {"present": False}
CLAUDE_ENV_KEYS = (
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_CUSTOM_MODEL_OPTION",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "DISABLE_TELEMETRY",
)

ROOT_BEGIN = "# >>> poolside-s21 managed Codex defaults >>>"
ROOT_END = "# <<< poolside-s21 managed Codex defaults <<<"
PROVIDER_BEGIN = "# >>> poolside-s21 managed Codex provider >>>"
PROVIDER_END = "# <<< poolside-s21 managed Codex provider <<<"
ORIGINAL_PREFIX = "# poolside-s21-original: "
ROOT_KEYS = {
    "model",
    "model_provider",
    "model_context_window",
    "model_supports_reasoning_summaries",
    "web_search",
}


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".poolside-s21.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists() or not path.read_text(encoding="utf-8").strip():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"Expected a JSON object in {path}")
    return value


def capture(mapping: dict[str, Any], key: str) -> dict[str, Any]:
    if key in mapping:
        return {"present": True, "value": mapping[key]}
    return dict(MISSING)


def restore_value(mapping: dict[str, Any], key: str, state: dict[str, Any]) -> None:
    if state.get("present"):
        mapping[key] = state.get("value")
    else:
        mapping.pop(key, None)


def claude_apply(settings_path: Path, state_path: Path, key: str, base_url: str, model: str) -> None:
    settings = load_json(settings_path)
    env_was_present = "env" in settings
    env = settings.get("env")
    if env is None:
        env = {}
        settings["env"] = env
    if not isinstance(env, dict):
        raise SystemExit(f"Expected 'env' to be an object in {settings_path}")

    if not state_path.exists():
        state = {
            "model": capture(settings, "model"),
            "env_was_present": env_was_present,
            "env": {name: capture(env, name) for name in CLAUDE_ENV_KEYS},
        }
        atomic_write(state_path, json.dumps(state, indent=2, sort_keys=True) + "\n")

    settings["model"] = "opus"
    env.update(
        {
            "ANTHROPIC_BASE_URL": base_url,
            "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_API_KEY": key,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
            "ANTHROPIC_CUSTOM_MODEL_OPTION": model,
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Poolside Laguna S 2.1 (local)",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Local Poolside model through LiteLLM and Ollama",
            "CLAUDE_CODE_USE_BEDROCK": "0",
            "CLAUDE_CODE_USE_VERTEX": "0",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_TELEMETRY": "1",
        }
    )
    atomic_write(settings_path, json.dumps(settings, indent=2, sort_keys=True) + "\n")


def claude_restore(settings_path: Path, state_path: Path) -> None:
    if not state_path.exists():
        return
    state = load_json(state_path)
    settings = load_json(settings_path)
    env = settings.get("env")
    if not isinstance(env, dict):
        env = {}
        settings["env"] = env

    restore_value(settings, "model", state.get("model", MISSING))
    env_state = state.get("env", {})
    for name in CLAUDE_ENV_KEYS:
        restore_value(env, name, env_state.get(name, MISSING))
    if not state.get("env_was_present", False) and not env:
        settings.pop("env", None)

    atomic_write(settings_path, json.dumps(settings, indent=2, sort_keys=True) + "\n")
    state_path.unlink(missing_ok=True)


def remove_marked_block(lines: list[str], begin: str, end: str) -> list[str]:
    result: list[str] = []
    inside = False
    for line in lines:
        if line.rstrip("\n") == begin:
            inside = True
            continue
        if line.rstrip("\n") == end:
            inside = False
            continue
        if not inside:
            result.append(line)
    return result


def codex_clean_lines(text: str) -> list[str]:
    lines = text.splitlines(keepends=True)
    lines = remove_marked_block(lines, ROOT_BEGIN, ROOT_END)
    lines = remove_marked_block(lines, PROVIDER_BEGIN, PROVIDER_END)
    return lines


def codex_apply(path: Path, auth_command: str, base_url: str, model: str, context: int) -> None:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = codex_clean_lines(text)

    in_root = True
    rewritten: list[str] = []
    key_pattern = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=")
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("["):
            in_root = False
        match = key_pattern.match(line)
        if in_root and match and match.group(1) in ROOT_KEYS:
            rewritten.append(ORIGINAL_PREFIX + line)
        else:
            rewritten.append(line)

    root = (
        f"{ROOT_BEGIN}\n"
        f'model = "{model}"\n'
        'model_provider = "poolside_s21_local"\n'
        f"model_context_window = {context}\n"
        "model_supports_reasoning_summaries = false\n"
        'web_search = "disabled"\n'
        f"{ROOT_END}\n\n"
    )
    provider = (
        f"\n{PROVIDER_BEGIN}\n"
        "[model_providers.poolside_s21_local]\n"
        'name = "Poolside Laguna S 2.1 via local LiteLLM"\n'
        f'base_url = "{base_url}/v1"\n'
        'wire_api = "responses"\n'
        "requires_openai_auth = false\n"
        "supports_websockets = false\n"
        "request_max_retries = 1\n"
        "stream_max_retries = 1\n"
        "stream_idle_timeout_ms = 1200000\n"
        "[model_providers.poolside_s21_local.auth]\n"
        f"command = {json.dumps(auth_command)}\n"
        "timeout_ms = 5000\n"
        "refresh_interval_ms = 300000\n"
        f"{PROVIDER_END}\n"
    )
    body = "".join(rewritten).lstrip("\n")
    atomic_write(path, root + body.rstrip() + provider)


def codex_restore(path: Path) -> None:
    if not path.exists():
        return
    lines = codex_clean_lines(path.read_text(encoding="utf-8"))
    restored = []
    for line in lines:
        if line.startswith(ORIGINAL_PREFIX):
            restored.append(line[len(ORIGINAL_PREFIX):])
        else:
            restored.append(line)
    atomic_write(path, "".join(restored).lstrip("\n"))


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("missing command")
    command = sys.argv[1]
    if command == "claude-apply" and len(sys.argv) == 7:
        claude_apply(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6])
    elif command == "claude-restore" and len(sys.argv) == 4:
        claude_restore(Path(sys.argv[2]), Path(sys.argv[3]))
    elif command == "codex-apply" and len(sys.argv) == 7:
        codex_apply(Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]))
    elif command == "codex-restore" and len(sys.argv) == 3:
        codex_restore(Path(sys.argv[2]))
    else:
        raise SystemExit(f"invalid arguments for {command!r}")


if __name__ == "__main__":
    main()
PY
  chmod 700 "${HELPER_PY}"
}

run_python_helper() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "${HELPER_PY}" "$@"
  elif [ -n "${UV_BIN}" ]; then
    "${UV_BIN}" run --python 3.12 "${HELPER_PY}" "$@"
  else
    fatal "Python 3 or uv is required to safely edit harness configuration."
  fi
}

write_codex_profile() {
  cat > "${CODEX_PROFILE}" <<EOF
model = "${LITELLM_MODEL}"
model_provider = "poolside_s21_local"
model_context_window = ${CONTEXT_LENGTH}
model_supports_reasoning_summaries = false
web_search = "disabled"

[model_providers.poolside_s21_local]
name = "Poolside Laguna S 2.1 via local LiteLLM"
base_url = "${LITELLM_URL}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 1
stream_max_retries = 1
stream_idle_timeout_ms = 1200000

[model_providers.poolside_s21_local.auth]
command = "${STATE_DIR}/print-litellm-key.sh"
timeout_ms = 5000
refresh_interval_ms = 300000
EOF
  chmod 600 "${CODEX_PROFILE}"
}

write_wrappers() {
  cat > "${STATE_DIR}/print-litellm-key.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. $(printf '%q' "${RUNTIME_ENV}")
printf '%s' "\${LITELLM_MASTER_KEY}"
EOF

  cat > "${BIN_DIR}/pool-poolside" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export POOLSIDE_STANDALONE_BASE_URL="${LITELLM_URL}/v1"
export POOLSIDE_STANDALONE_MODEL="${LITELLM_MODEL}"
export POOLSIDE_API_KEY="${LITELLM_MASTER_KEY}"
exec $(printf '%q' "${POOL_BIN}") "\$@"
EOF

  cat > "${BIN_DIR}/claude-poolside" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export ANTHROPIC_BASE_URL="${LITELLM_URL}"
export ANTHROPIC_AUTH_TOKEN="${LITELLM_MASTER_KEY}"
export ANTHROPIC_API_KEY="${LITELLM_MASTER_KEY}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${LITELLM_MODEL}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${LITELLM_MODEL}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${LITELLM_MODEL}"
export ANTHROPIC_CUSTOM_MODEL_OPTION="${LITELLM_MODEL}"
export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="Poolside Laguna S 2.1 (local)"
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="Local Poolside model through LiteLLM and Ollama"
export CLAUDE_CODE_USE_BEDROCK=0
export CLAUDE_CODE_USE_VERTEX=0
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
exec $(printf '%q' "${CLAUDE_BIN}") --settings $(printf '%q' "${CLAUDE_LOCAL_SETTINGS}") --model opus "\$@"
EOF

  cat > "${BIN_DIR}/codex-poolside" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec $(printf '%q' "${CODEX_BIN}") --profile poolside-s21 "\$@"
EOF

  chmod 700 "${STATE_DIR}/print-litellm-key.sh" \
    "${BIN_DIR}/pool-poolside" "${BIN_DIR}/claude-poolside" "${BIN_DIR}/codex-poolside"
}

apply_repoints() {
  write_config_helper
  if [ "${REPOINT_OPUS}" -eq 1 ]; then
    log "Persistently repointing Claude Code's Opus selection to ${LITELLM_MODEL}."
    run_python_helper claude-apply "${CLAUDE_SETTINGS}" "${CLAUDE_STATE}" \
      "${LITELLM_MASTER_KEY}" "${LITELLM_URL}" "${LITELLM_MODEL}"
  fi

  if [ "${REPOINT_CODEX}" -eq 1 ]; then
    log "Persistently repointing Codex CLI defaults to ${LITELLM_MODEL}."
    run_python_helper codex-apply "${CODEX_CONFIG}" "${STATE_DIR}/print-litellm-key.sh" \
      "${LITELLM_URL}" "${LITELLM_MODEL}" "${CONTEXT_LENGTH}"
  fi
}

restore_harnesses() {
  ensure_dirs
  configure_path
  UV_BIN="$(find_executable uv "${BIN_DIR}/uv" "${HOME}/.cargo/bin/uv" || true)"
  write_config_helper
  log "Restoring Claude Code and Codex CLI configuration."
  run_python_helper claude-restore "${CLAUDE_SETTINGS}" "${CLAUDE_STATE}"
  run_python_helper codex-restore "${CODEX_CONFIG}"
  log "Persistent harness repointing has been removed. Local wrappers and services were left intact."
}

record_test() {
  local status="$1" name="$2" detail="${3:-}"
  printf '%-5s  %-31s %s\n' "${status}" "${name}" "${detail}" | tee -a "${TEST_REPORT}"
}

run_capture() {
  local timeout="$1" output="$2"
  shift 2
  local pid watcher rc timed_out_file
  timed_out_file="${output}.timeout"
  rm -f "${timed_out_file}"

  "$@" >"${output}" 2>&1 &
  pid=$!
  (
    sleep "${timeout}"
    if kill -0 "${pid}" >/dev/null 2>&1; then
      printf 'timeout\n' > "${timed_out_file}"
      pkill -TERM -P "${pid}" >/dev/null 2>&1 || true
      kill -TERM "${pid}" >/dev/null 2>&1 || true
      sleep 5
      pkill -KILL -P "${pid}" >/dev/null 2>&1 || true
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  ) &
  watcher=$!

  set +e
  wait "${pid}"
  rc=$?
  set -e
  kill "${watcher}" >/dev/null 2>&1 || true
  wait "${watcher}" >/dev/null 2>&1 || true

  if [ -f "${timed_out_file}" ]; then
    rm -f "${timed_out_file}"
    return 124
  fi
  return "${rc}"
}

assert_marker_file() {
  local name="$1" marker="$2" file="$3"
  if grep -Fq "${marker}" "${file}"; then
    record_test PASS "${name}"
    return 0
  fi
  record_test FAIL "${name}" "marker not found"
  tail -n 80 "${file}" >&2 || true
  return 1
}

curl_json_test() {
  local name="$1" marker="$2" endpoint="$3" auth_header="$4" body="$5"
  local output="${STATE_DIR}/test-${name// /-}.json"
  local args=(-sS --fail-with-body --max-time "${INFERENCE_TIMEOUT}" \
    -H 'Content-Type: application/json')
  if [ -n "${auth_header}" ]; then
    args+=(-H "${auth_header}")
  fi
  args+=(-d "${body}" "${endpoint}")
  if ! /usr/bin/curl "${args[@]}" > "${output}" 2>&1; then
    record_test FAIL "${name}" "HTTP request failed"
    tail -n 80 "${output}" >&2 || true
    return 1
  fi
  assert_marker_file "${name}" "${marker}" "${output}"
}

run_live_tests() {
  : > "${TEST_REPORT}"
  printf 'Poolside S2.1 validation - %s\n\n' "$(date)" >> "${TEST_REPORT}"
  local failures=0

  if [ "$(/usr/sbin/sysctl -n hw.memsize)" -ge "${REQUIRED_RAM_BYTES}" ]; then
    record_test PASS "128 GiB memory check"
  else
    record_test FAIL "128 GiB memory check"
    failures=$((failures + 1))
  fi

  if url_healthy "${OLLAMA_URL}/api/version"; then
    record_test PASS "Ollama API health"
  else
    record_test FAIL "Ollama API health"
    failures=$((failures + 1))
  fi

  if "${OLLAMA_BIN}" list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fqx "${MODEL_LOCAL}"; then
    record_test PASS "Ollama local model tag"
  else
    record_test FAIL "Ollama local model tag"
    failures=$((failures + 1))
  fi

  local marker body
  marker="OLLAMA_PROTOCOL_$(/usr/bin/openssl rand -hex 6)"
  body="{\"model\":\"${MODEL_LOCAL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly ${marker} and nothing else.\"}],\"stream\":false,\"temperature\":0,\"max_tokens\":32}"
  curl_json_test "Ollama chat protocol" "${marker}" "${OLLAMA_URL}/v1/chat/completions" "" "${body}" || failures=$((failures + 1))

  if /usr/bin/curl -fsS --max-time 10 -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
      "${LITELLM_URL}/v1/models" | grep -Fq "${LITELLM_MODEL}"; then
    record_test PASS "LiteLLM model discovery"
  else
    record_test FAIL "LiteLLM model discovery"
    failures=$((failures + 1))
  fi

  marker="LITELLM_CHAT_$(/usr/bin/openssl rand -hex 6)"
  body="{\"model\":\"${LITELLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly ${marker} and nothing else.\"}],\"stream\":false,\"temperature\":0,\"max_tokens\":32}"
  curl_json_test "LiteLLM chat completions" "${marker}" "${LITELLM_URL}/v1/chat/completions" \
    "Authorization: Bearer ${LITELLM_MASTER_KEY}" "${body}" || failures=$((failures + 1))

  marker="LITELLM_ANTHROPIC_$(/usr/bin/openssl rand -hex 6)"
  body="{\"model\":\"${LITELLM_MODEL}\",\"max_tokens\":32,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly ${marker} and nothing else.\"}]}"
  local anthropic_out="${STATE_DIR}/test-LiteLLM-Anthropic-Messages.json"
  if /usr/bin/curl -sS --fail-with-body --max-time "${INFERENCE_TIMEOUT}" \
      -H 'Content-Type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -H "x-api-key: ${LITELLM_MASTER_KEY}" \
      -d "${body}" "${LITELLM_URL}/v1/messages" > "${anthropic_out}" 2>&1; then
    assert_marker_file "LiteLLM Anthropic Messages" "${marker}" "${anthropic_out}" || failures=$((failures + 1))
  else
    record_test FAIL "LiteLLM Anthropic Messages" "HTTP request failed"
    tail -n 80 "${anthropic_out}" >&2 || true
    failures=$((failures + 1))
  fi

  marker="LITELLM_RESPONSES_$(/usr/bin/openssl rand -hex 6)"
  body="{\"model\":\"${LITELLM_MODEL}\",\"input\":\"Reply with exactly ${marker} and nothing else.\",\"temperature\":0,\"max_output_tokens\":32}"
  curl_json_test "LiteLLM Responses API" "${marker}" "${LITELLM_URL}/v1/responses" \
    "Authorization: Bearer ${LITELLM_MASTER_KEY}" "${body}" || failures=$((failures + 1))

  local harness_dir harness_marker output rc
  harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/poolside-s21-harness.XXXXXX")"
  printf '# Local harness validation\n' > "${harness_dir}/README.md"
  (cd "${harness_dir}" && /usr/bin/git init -q)

  harness_marker="POOL_HARNESS_$(/usr/bin/openssl rand -hex 8)"
  output="${STATE_DIR}/test-pool-harness.jsonl"
  set +e
  run_capture "${INFERENCE_TIMEOUT}" "${output}" env \
    POOLSIDE_STANDALONE_BASE_URL="${LITELLM_URL}/v1" \
    POOLSIDE_STANDALONE_MODEL="${LITELLM_MODEL}" \
    POOLSIDE_API_KEY="${LITELLM_MASTER_KEY}" \
    "${POOL_BIN}" --sandbox disabled exec -o json -d "${harness_dir}" \
    -p "Reply with exactly ${harness_marker} and nothing else. Do not use tools."
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ] && grep -Fq "${harness_marker}" "${output}"; then
    record_test PASS "Poolside CLI local harness"
  else
    record_test FAIL "Poolside CLI local harness" "exit=${rc}"
    tail -n 100 "${output}" >&2 || true
    failures=$((failures + 1))
  fi

  harness_marker="CLAUDE_TOOL_$(/usr/bin/openssl rand -hex 8)"
  printf '%s\n' "${harness_marker}" > "${harness_dir}/needle.txt"
  output="${STATE_DIR}/test-claude-harness.json"
  set +e
  if [ "${REPOINT_OPUS}" -eq 1 ]; then
    (
      cd "${harness_dir}"
      run_capture "${INFERENCE_TIMEOUT}" "${output}" env \
        -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
        "${CLAUDE_BIN}" --model opus -p \
        "Use the Read tool to read needle.txt, then output exactly its contents and nothing else." \
        --allowedTools Read --output-format json
    )
  else
    (
      cd "${harness_dir}"
      run_capture "${INFERENCE_TIMEOUT}" "${output}" "${BIN_DIR}/claude-poolside" -p \
        "Use the Read tool to read needle.txt, then output exactly its contents and nothing else." \
        --allowedTools Read --output-format json
    )
  fi
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ] && grep -Fq "${harness_marker}" "${output}"; then
    if [ "${REPOINT_OPUS}" -eq 1 ]; then
      record_test PASS "Claude Opus persisted repoint"
    else
      record_test PASS "Claude Code local wrapper"
    fi
  else
    if [ "${REPOINT_OPUS}" -eq 1 ]; then
      record_test FAIL "Claude Opus persisted repoint" "exit=${rc}"
    else
      record_test FAIL "Claude Code local wrapper" "exit=${rc}"
    fi
    tail -n 100 "${output}" >&2 || true
    failures=$((failures + 1))
  fi

  harness_marker="CODEX_TOOL_$(/usr/bin/openssl rand -hex 8)"
  printf '%s\n' "${harness_marker}" > "${harness_dir}/needle.txt"
  output="${STATE_DIR}/test-codex-harness.jsonl"
  set +e
  if [ "${REPOINT_CODEX}" -eq 1 ]; then
    (
      cd "${harness_dir}"
      run_capture "${INFERENCE_TIMEOUT}" "${output}" \
        "${CODEX_BIN}" exec --skip-git-repo-check --sandbox read-only --json \
        "Read needle.txt from the current repository, then output exactly its contents and nothing else."
    )
  else
    (
      cd "${harness_dir}"
      run_capture "${INFERENCE_TIMEOUT}" "${output}" "${BIN_DIR}/codex-poolside" exec \
        --skip-git-repo-check --sandbox read-only --json \
        "Read needle.txt from the current repository, then output exactly its contents and nothing else."
    )
  fi
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ] && grep -Fq "${harness_marker}" "${output}"; then
    if [ "${REPOINT_CODEX}" -eq 1 ]; then
      record_test PASS "Codex persisted repoint"
    else
      record_test PASS "Codex local wrapper"
    fi
  else
    if [ "${REPOINT_CODEX}" -eq 1 ]; then
      record_test FAIL "Codex persisted repoint" "exit=${rc}"
    else
      record_test FAIL "Codex local wrapper" "exit=${rc}"
    fi
    tail -n 100 "${output}" >&2 || true
    failures=$((failures + 1))
  fi

  rm -rf "${harness_dir}"

  if [ "${failures}" -ne 0 ]; then
    printf '\n%d validation test(s) failed.\n' "${failures}" | tee -a "${TEST_REPORT}"
    warn "Review ${TEST_REPORT}, ${LOG_DIR}/ollama-error.log, and ${LOG_DIR}/litellm-error.log."
    return 1
  fi

  printf '\nAll validation tests passed.\n' | tee -a "${TEST_REPORT}"
  return 0
}

resolve_existing_tools() {
  UV_BIN="$(find_executable uv "${BIN_DIR}/uv" "${HOME}/.cargo/bin/uv" || true)"
  OLLAMA_BIN="$(find_executable ollama \
    "/Applications/Ollama.app/Contents/Resources/ollama" \
    "${HOME}/Applications/Ollama.app/Contents/Resources/ollama" || true)"
  LITELLM_BIN="$(find_executable litellm "${LITELLM_VENV}/bin/litellm" "${BIN_DIR}/litellm" || true)"
  POOL_BIN="$(find_executable pool "${BIN_DIR}/pool" || true)"
  CLAUDE_BIN="$(find_executable claude "${BIN_DIR}/claude" "${HOME}/.claude/local/claude" || true)"
  CODEX_BIN="$(find_executable codex "${BIN_DIR}/codex" || true)"

  [ -n "${UV_BIN}" ] || fatal "uv is missing; rerun without --test-only."
  [ -n "${OLLAMA_BIN}" ] || fatal "Ollama is missing; rerun without --test-only."
  [ -n "${LITELLM_BIN}" ] || fatal "LiteLLM is missing; rerun without --test-only."
  [ -n "${POOL_BIN}" ] || fatal "Poolside Agent CLI is missing; rerun without --test-only."
  [ -n "${CLAUDE_BIN}" ] || fatal "Claude Code is missing; rerun without --test-only."
  [ -n "${CODEX_BIN}" ] || fatal "Codex CLI is missing; rerun without --test-only."
}

detect_existing_repoints() {
  if [ -f "${CLAUDE_STATE}" ]; then
    REPOINT_OPUS=1
  fi
  if [ -f "${CODEX_CONFIG}" ] && grep -Fq '# >>> poolside-s21 managed Codex defaults >>>' "${CODEX_CONFIG}"; then
    REPOINT_CODEX=1
  fi
}

print_summary() {
  cat <<EOF

Installation paths
------------------
Model runtime:       ${OLLAMA_URL}
LiteLLM gateway:     ${LITELLM_URL}
LiteLLM model name:  ${LITELLM_MODEL}
Context length:      ${CONTEXT_LENGTH}
Configuration:       ${CONFIG_DIR}
Logs:                ${LOG_DIR}
Validation report:   ${TEST_REPORT}

Local commands
--------------
pool-poolside
claude-poolside
codex-poolside

The PATH change takes effect automatically in new login shells. For the
current shell, run:
  source "${ZPROFILE}"
EOF

  if [ "${REPOINT_OPUS}" -eq 1 ]; then
    printf '\nClaude Code Opus is persistently routed to the local model.\n'
  fi
  if [ "${REPOINT_CODEX}" -eq 1 ]; then
    printf 'Codex CLI defaults are persistently routed to the local model.\n'
  fi
  if [ "${REPOINT_OPUS}" -eq 1 ] || [ "${REPOINT_CODEX}" -eq 1 ]; then
    printf 'Revert persistent repointing with: %s --restore-harnesses\n' "$0"
  fi
}

main() {
  parse_args "$@"

  if [ "${RESTORE_HARNESSES}" -eq 1 ]; then
    restore_harnesses
    exit 0
  fi

  check_platform
  ensure_dirs
  configure_path
  detect_existing_repoints

  if [ "${TEST_ONLY}" -eq 1 ]; then
    resolve_existing_tools
    load_or_create_key
    write_runtime_config
    write_codex_profile
    write_wrappers
    apply_repoints
  else
    install_uv
    install_ollama
    start_ollama
    check_disk_for_pull
    install_litellm
    install_pool
    install_claude
    install_codex
    load_or_create_key
    write_runtime_config
    write_codex_profile
    write_wrappers
    pull_and_create_model
    start_litellm
    apply_repoints
  fi

  if [ "${TEST_ONLY}" -eq 1 ]; then
    start_ollama
    start_litellm
  fi

  if [ "${SKIP_TESTS}" -eq 0 ]; then
    run_live_tests
  else
    warn "Live validation was skipped."
  fi

  print_summary
}

main "$@"
