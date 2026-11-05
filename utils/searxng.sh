#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck disable=SC2001

# Script options from the environment:
SEARXNG_UWSGI_USE_SOCKET="${SEARXNG_UWSGI_USE_SOCKET:-true}"

# shellcheck source=utils/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=utils/lib_redis.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_redis.sh"
# shellcheck source=utils/lib_valkey.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_valkey.sh"
# shellcheck source=utils/brand.sh
source "${REPO_ROOT}/utils/brand.sh"

SERVICE_NAME="searxng"
SERVICE_USER="searxng"
SERVICE_HOME="/usr/local/searxng"
SERVICE_GROUP="searxng"

SEARXNG_SRC="${SERVICE_HOME}/searxng-src"
# shellcheck disable=SC2034
SEARXNG_STATIC="${SEARXNG_SRC}/searx/static"

SEARXNG_PYENV="${SERVICE_HOME}/searx-pyenv"
SEARXNG_SETTINGS_PATH="/etc/searxng/settings.yml"
SEARXNG_UWSGI_APP="searxng.ini"

SEARXNG_INTERNAL_HTTP="${SEARXNG_BIND_ADDRESS}:${SEARXNG_PORT}"
if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
    SEARXNG_UWSGI_SOCKET="${SERVICE_HOME}/run/socket"
else
    SEARXNG_UWSGI_SOCKET=
fi

# SEARXNG_URL: the public URL of the instance (https://example.org/searxng).  The
# value is taken from environment ${SEARXNG_URL} in ./utils/brand.env.  This
# variable is an empty string if server.base_url in the settings.yml is set to
# 'false'.

SEARXNG_URL="${SEARXNG_URL:-http://$(uname -n)/searxng}"
SEARXNG_URL="${SEARXNG_URL%/}" # if exists, remove trailing slash
SEARXNG_URL_PATH="$(echo "${SEARXNG_URL}" | sed -e 's,^.*://[^/]*\(/.*\),\1,g')"
[[ "${SEARXNG_URL_PATH}" == "${SEARXNG_URL}" ]] && SEARXNG_URL_PATH=/

# Apache settings

APACHE_SEARXNG_SITE="searxng.conf"

# nginx settings

NGINX_SEARXNG_SITE="searxng.conf"

# apt packages

SEARXNG_PACKAGES_debian="\
python3-dev python3-babel python3-venv python-is-python3
uwsgi uwsgi-plugin-python3
git build-essential libxslt-dev zlib1g-dev libffi-dev libssl-dev"

SEARXNG_BUILD_PACKAGES_debian="\
graphviz imagemagick texlive-xetex librsvg2-bin
texlive-latex-recommended texlive-extra-utils fonts-dejavu
latexmk shellcheck"

# pacman packages

SEARXNG_PACKAGES_arch="\
python python-pip python-lxml python-babel
uwsgi uwsgi-plugin-python
git base-devel libxml2"

SEARXNG_BUILD_PACKAGES_arch="\
graphviz imagemagick texlive-bin extra/librsvg
texlive-core texlive-latexextra ttf-dejavu shellcheck"

# dnf packages

SEARXNG_PACKAGES_fedora="\
python python-pip python-lxml python-babel python3-devel
uwsgi uwsgi-plugin-python3
git @development-tools libxml2 openssl"

SEARXNG_BUILD_PACKAGES_fedora="\
graphviz graphviz-gd ImageMagick librsvg2-tools
texlive-xetex-bin texlive-collection-fontsrecommended
texlive-collection-latex dejavu-sans-fonts dejavu-serif-fonts
dejavu-sans-mono-fonts ShellCheck"

case $DIST_ID-$DIST_VERS in
    ubuntu-18.04)
        SEARXNG_PACKAGES="${SEARXNG_PACKAGES_debian}"
        SEARXNG_BUILD_PACKAGES="${SEARXNG_BUILD_PACKAGES_debian}"
        APACHE_PACKAGES="$APACHE_PACKAGES libapache2-mod-proxy-uwsgi"
        ;;
    ubuntu-* | debian-*|linuxmint-*)
        SEARXNG_PACKAGES="${SEARXNG_PACKAGES_debian} python-is-python3"
        SEARXNG_BUILD_PACKAGES="${SEARXNG_BUILD_PACKAGES_debian}"
        ;;
    arch-*)
        SEARXNG_PACKAGES="${SEARXNG_PACKAGES_arch}"
        SEARXNG_BUILD_PACKAGES="${SEARXNG_BUILD_PACKAGES_arch}"
        ;;
    fedora-*)
        SEARXNG_PACKAGES="${SEARXNG_PACKAGES_fedora}"
        SEARXNG_BUILD_PACKAGES="${SEARXNG_BUILD_PACKAGES_fedora}"
        ;;
esac

_service_prefix="  ${_Yellow}|${SERVICE_USER}|${_creset} "

usage() {

    # shellcheck disable=SC1117
    cat <<EOF
usage:
  $(basename "$0") install    [all|user|pyenv|settings|uwsgi|valkey|nginx|https|apache|searxng-src|packages|buildhost]
  $(basename "$0") remove     [all|user|pyenv|settings|uwsgi|valkey|redis|nginx|https|apache|packages|verify|repo]
  $(basename "$0") instance   [cmd|update|check|localtest|inspect]
install|remove:
  all           : complete (de-) installation of the SearXNG service
  user          : service user '${SERVICE_USER}' (${SERVICE_HOME})
  pyenv         : virtualenv (python) in ${SEARXNG_PYENV}
  settings      : settings from ${SEARXNG_SETTINGS_PATH}
  uwsgi         : SearXNG's uWSGI app ${SEARXNG_UWSGI_APP}
  nginx         : HTTP site ${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}
  apache        : HTTP site ${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}
install:
  valkey        : install a local valkey server
remove:
  redis         : remove redis (local build or packages) after confirmation
  valkey        : remove valkey (packages, user, APT backports source) after confirmation
  packages      : purge OS packages (uwsgi, valkey, nginx, ...) with confirmation per group
  verify        : search the system for SearXNG leftovers
  repo          : delete this repository checkout
environment:
  SEARXNG_HTTP_SERVER=nginx|apache|none  skip the web server question on install
install:
  searxng-src   : clone ${GIT_URL} into ${SEARXNG_SRC}
  packages      : installs packages from OS package manager required by SearXNG
  buildhost     : installs packages from OS package manager required by a SearXNG buildhost
instance:
  update        : update SearXNG instance (git fetch + reset & update settings.yml)
  check         : run checks from utils/searxng_check.py in the active installation
  inspect       : run some small tests and inspect SearXNG's server status and log
  get_setting   : get settings value from running SearXNG instance
  cmd           : run command in SearXNG instance's environment (e.g. bash)
EOF
    searxng.instance.env
    [[ -n ${1} ]] && err_msg "$1"
}

searxng.instance.env() {
    echo "uWSGI:"
    if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
        echo "  SEARXNG_UWSGI_SOCKET : ${SEARXNG_UWSGI_SOCKET}"
    else
        echo "  SEARXNG_INTERNAL_HTTP: ${SEARXNG_INTERNAL_HTTP}"
    fi
    cat <<EOF
environment:
  GIT_URL              : ${GIT_URL}
  GIT_BRANCH           : ${GIT_BRANCH}
  SEARXNG_URL          : ${SEARXNG_URL}
  SEARXNG_PORT         : ${SEARXNG_PORT}
  SEARXNG_BIND_ADDRESS : ${SEARXNG_BIND_ADDRESS}
EOF
}

main() {
    case $1 in
        install | remove | instance)
            nginx_distro_setup
            apache_distro_setup
            uWSGI_distro_setup
            [[ $1 == install ]] && searxng.ensure_tools
            required_commands \
                sudo systemctl install git wget curl ||
                exit
            ensure_cache_dir
            ;;
    esac

    local _usage="unknown or missing $1 command $2"

    case $1 in
        --getenv)
            var="$2"
            echo "${!var}"
            exit 0
            ;;
        --cmd)
            shift
            "$@"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        install)
            sudo_or_exit
            case $2 in
                all) searxng.install.all ;;
                user) searxng.install.user ;;
                pyenv) searxng.install.pyenv ;;
                searxng-src) searxng.install.clone ;;
                settings) searxng.install.settings ;;
                uwsgi) searxng.install.uwsgi ;;
                packages) searxng.install.packages ;;
                buildhost) searxng.install.buildhost ;;
                nginx) searxng.nginx.install ;;
                https) searxng.nginx.https ;;
                apache) searxng.apache.install ;;
                valkey) searxng.install.valkey ;;
                *)
                    usage "$_usage"
                    exit 42
                    ;;
            esac
            ;;
        remove)
            sudo_or_exit
            case $2 in
                all) searxng.remove.all ;;
                user) drop_service_account "${SERVICE_USER}" ;;
                pyenv) searxng.remove.pyenv ;;
                settings) searxng.remove.settings ;;
                uwsgi) searxng.remove.uwsgi ;;
                apache) searxng.apache.remove ;;
                https) searxng.remove.https ;;
                nginx) searxng.nginx.remove ;;
                packages) searxng.remove.packages ;;
                verify) searxng.remove.verify ;;
                repo) searxng.remove.repo ;;
                valkey) searxng.remove.valkey ;;
                redis) searxng.remove.redis ;;
                *)
                    usage "$_usage"
                    exit 42
                    ;;
            esac
            ;;
        instance)
            case $2 in
                update)
                    sudo_or_exit
                    searxng.instance.update
                    ;;
                check)
                    sudo_or_exit
                    searxng.instance.self.call searxng.check
                    ;;
                inspect)
                    sudo_or_exit
                    searxng.instance.inspect
                    ;;
                cmd)
                    sudo_or_exit
                    shift
                    shift
                    searxng.instance.exec "$@"
                    ;;
                get_setting)
                    shift
                    shift
                    searxng.instance.get_setting "$@"
                    ;;
                call)
                    # call a function in instance's environment
                    shift
                    shift
                    searxng.instance.self.call "$@"
                    ;;
                _call)
                    shift
                    shift
                    "$@"
                    ;;
                *)
                    usage "$_usage"
                    exit 42
                    ;;
            esac
            ;;
        *)
            local cmd="$1"
            _type="$(type -t "$cmd")"
            if [ "$_type" != 'function' ]; then
                usage "unknown or missing command $1"
                exit 42
            else
                "$cmd" "$@"
            fi
            ;;
    esac
}

# ==============================================================================
# lib.sh builds config templates in ${REPO_ROOT}/cache as ${SUDO_USER}: when the
# repository lives in /usr/local/searxng (root owned) that mkdir fails.
# ==============================================================================
ensure_cache_dir() {
    if [[ -n "${SUDO_USER}" && "${SUDO_USER}" != "root" ]]; then
        mkdir -p "${REPO_ROOT}/cache"
        chown -R "${SUDO_USER}:" "${REPO_ROOT}/cache"
    fi
}

# ==============================================================================
# Verify that the service user can traverse and read the source directory
# ==============================================================================
check_source_accessibility() {
    local current_path="$PWD"
    local temp_user="${SERVICE_USER:-searxng}"
    local target="${SERVICE_HOME:-/usr/local/searxng}"

    # already running from the service home: just make sure the service user
    # owns the directory itself (non-recursive), then continue
    if [[ "$current_path" == "$target" ]]; then
        chown "${temp_user}:${temp_user}" "$target"
        return 0
    fi

    # service user can read the source: nothing to do
    if sudo -u "$temp_user" test -r "$current_path" 2>/dev/null; then
        return 0
    fi
    # only handle the private-home-directory case
    if [[ ! "$current_path" =~ ^/home/ ]]; then
        return 0
    fi

    info_msg "'${temp_user}' cannot read ${current_path}: relocating repository to ${target}"

    mkdir -p "$target"
    cp -a "$current_path"/. "$target"/

    # Keep root as owner (the installer runs as root). A repo owned by the
    # service user makes root's git calls fail with "dubious ownership",
    # leaving GIT_URL / GIT_BRANCH empty. World-readable is enough for cloning.
    # (skip the service user's own work dirs so reruns don't take them away)
    find "$target" -mindepth 1 \
        \( -path "$target/searxng-src" -o -path "$target/searx-pyenv" \) -prune \
        -o -exec chown root:root {} +
    chmod -R a+rX "$target"
    # ...but the service user needs write access to its own home directory
    # (non-recursive) to create searxng-src, searx-pyenv, caches, etc.
    chown "${temp_user}:${temp_user}" "$target"

    # trust the new location before the script re-reads git state
    local dir
    for dir in "$target" "$target/.git"; do
        if ! git config --system --get-all safe.directory | grep -qxF "$dir"; then
            git config --system --add safe.directory "$dir"
        fi
    done

    if ! git -C "$target" remote get-url origin >/dev/null 2>&1; then
        warn_msg "no 'origin' remote in ${target}: add one with 'git remote add origin <url>' if updates should come from your fork"
    fi

    info_msg "restarting installer from ${target}"
    cd "$target" || exit 1
    exec ./utils/searxng.sh install all
}

searxng.install.all() {
    rst_title "SearXNG installation" part

    local valkey_url

    rst_title "SearXNG"

    searxng.install.user
    wait_key 10

    check_source_accessibility

    searxng.install.packages
    wait_key 10
    searxng.install.clone
    wait_key
    searxng.install.pyenv
    wait_key
    searxng.install.settings
    wait_key
    searxng.instance.localtest
    wait_key
    searxng.install.uwsgi
    wait_key

    rst_title "Valkey DB"
    searxng.install.valkey.db

    rst_title "HTTP Server"
    searxng.install.http.site

    rst_title "Finalize installation"
    if ask_yn "Do you want to run some checks?" Yn; then
        searxng.instance.self.call searxng.check
    fi
    searxng.install.summary
}

searxng.install.valkey.db() {
    local valkey_url

    valkey_url=$(searxng.instance.get_setting valkey.url)

    if [ "${valkey_url}" = "False" ]; then
        rst_para "valkey DB connector is not configured in your instance"
    else
        rst_para "\
In your instance, valkey DB connector is configured at:

    ${valkey_url}
"
        if searxng.instance.exec python -c "from searx import valkeydb; valkeydb.initialize() or exit(42)"; then
            info_msg "SearXNG instance is able to connect valkey DB."
            return
        fi
    fi

    if ! [[ ${valkey_url} = valkey://localhost:6379/* ]]; then
        err_msg "SearXNG instance can't connect valkey DB / check valkey & your settings"
        return
    fi
    rst_para ".. but this valkey DB is not installed yet."

    if ask_yn "Do you want to install the valkey DB now?" Yn; then
        searxng.install.valkey
        uWSGI_restart "$SEARXNG_UWSGI_APP"
    fi
}

# ==============================================================================
# HTTPS for the nginx site (self-signed certificate by default)
#
# Environment (all optional):
#   SEARXNG_HTTPS_HOST   server name / certificate CN   (default: $(uname -n))
#   SEARXNG_HTTPS_CERT   path to an existing certificate (e.g. from certbot)
#   SEARXNG_HTTPS_KEY    path to the matching private key
# ==============================================================================
SEARXNG_HTTPS_DIR="/etc/ssl/searxng"
SEARXNG_HTTPS_CONF="/etc/nginx/conf.d/searxng-https.conf"

searxng.nginx.https() {
    rst_title "Install HTTPS site for SearXNG (nginx)" section

    if ! nginx_is_installed; then
        err_msg "Nginx packages are not installed: run '$(basename "$0") install nginx' first"
        return 42
    fi
    if [[ ! -f "${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}" ]]; then
        info_msg "SearXNG's nginx site is not installed yet: installing it first"
        searxng.nginx.install
    fi

    local host="${SEARXNG_HTTPS_HOST:-$(uname -n)}"
    local cert="${SEARXNG_HTTPS_CERT:-${SEARXNG_HTTPS_DIR}/searxng.crt}"
    local key="${SEARXNG_HTTPS_KEY:-${SEARXNG_HTTPS_DIR}/searxng.key}"

    if [[ -z "${SEARXNG_HTTPS_CERT}" ]]; then
        if [[ -f "$cert" && -f "$key" ]]; then
            info_msg "re-using existing self-signed certificate: $cert"
        else
            info_msg "create self-signed certificate for: ${host}, localhost, 127.0.0.1"
            mkdir -p "${SEARXNG_HTTPS_DIR}"
            openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
                -subj "/CN=${host}" \
                -addext "subjectAltName=DNS:${host},DNS:localhost,IP:127.0.0.1" \
                -keyout "$key" -out "$cert" 2>/dev/null ||
                die 42 "openssl failed to create the certificate"
            chmod 600 "$key"
            chmod 644 "$cert"
        fi
    elif [[ ! -f "$cert" || ! -f "$key" ]]; then
        die 42 "SEARXNG_HTTPS_CERT / SEARXNG_HTTPS_KEY: file not found"
    fi

    # only listen on IPv6 if the host has it (nginx refuses to start otherwise)
    local listen6=""
    if [[ -s /proc/net/if_inet6 ]]; then
        listen6="listen [::]:443 ssl;"
    fi

    info_msg "write ${SEARXNG_HTTPS_CONF}"
    cat >"${SEARXNG_HTTPS_CONF}" <<EOF
# generated by searxng.sh: HTTPS server block for SearXNG
server {
    listen 443 ssl;
    ${listen6}
    server_name ${host} localhost;

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SearXNG_SSL:2m;
    ssl_session_timeout 1d;

    # SearXNG's location block(s) (installed by 'install nginx')
    include ${NGINX_APPS_ENABLED}/*.conf;
}
EOF

    if ! nginx -t; then
        rm -f "${SEARXNG_HTTPS_CONF}"
        die 42 "nginx configuration test failed: HTTPS site removed again"
    fi
    nginx_reload

    local path="${SEARXNG_URL_PATH%/}/"
    if searxng.http.check https "${host}"; then
        info_msg "HTTPS is working: https://${host}${path} (HTTP ${SEARXNG_HTTP_CODE})"
    else
        err_msg "no usable answer from https://127.0.0.1${path} (HTTP ${SEARXNG_HTTP_CODE}) : check 'systemctl status nginx uwsgi'"
    fi
    if [[ -z "${SEARXNG_HTTPS_CERT}" ]]; then
        rst_para "\
The certificate is self-signed: browsers show a warning once, which you can
accept for a private instance.  For a public domain use a trusted certificate:
install certbot, obtain a certificate for your domain and re-run with
SEARXNG_HTTPS_HOST, SEARXNG_HTTPS_CERT and SEARXNG_HTTPS_KEY set."
    fi
}

searxng.remove.https() {
    rst_title "Remove HTTPS site for SearXNG (nginx)" section
    rm -f "${SEARXNG_HTTPS_CONF}"
    rm -rf "${SEARXNG_HTTPS_DIR}"
    if nginx_is_installed; then nginx_reload; fi
}

searxng.install.http.site() {
    local choice="${SEARXNG_HTTP_SERVER:-}" have_nginx=0 have_apache=0 busy

    if [[ -z ${choice} ]]; then
        nginx_is_installed && have_nginx=1
        apache_is_installed && have_apache=1
        if ((have_nginx && have_apache)); then
            info_msg "Both nginx and apache are installed on this host."
            _ask_choice "Which web server should serve SearXNG?" nginx apache none
            choice="${CHOICE}"
        elif ((have_nginx)); then
            info_msg "Nginx is installed on this host."
            if ask_yn "Use nginx as reverse proxy for SearXNG?" Yn; then choice=nginx; else choice=none; fi
        elif ((have_apache)); then
            info_msg "Apache is installed on this host."
            if ask_yn "Use apache as reverse proxy for SearXNG?" Yn; then choice=apache; else choice=none; fi
        else
            info_msg "No web server found on this host."
            rst_para "nginx is the recommended choice (used by the SearXNG documentation)."
            _ask_choice "Which web server do you want to install for SearXNG?" nginx apache none
            choice="${CHOICE}"
        fi
    fi

    case "${choice}" in
        nginx | apache)
            busy="$(ss -ltnpH 'sport = :80' 2>/dev/null | head -n1)"
            if [[ -n ${busy} ]] && ! [[ ${busy} =~ nginx|apache2|httpd ]]; then
                warn_msg "port 80 is already used by another service:"
                echo "  ${busy}"
                if ! ask_yn "Continue anyway?"; then
                    return 0
                fi
            fi
            ;;
    esac

    case "${choice}" in
        nginx)
            nginx_is_installed || FORCE_SELECTION=Y install_nginx
            searxng.nginx.install
            searxng.nginx.activate
            if ask_yn "Do you want to add a HTTPS site (self-signed certificate)?" Yn; then
                searxng.nginx.https
            fi
            ;;
        apache)
            apache_is_installed || FORCE_SELECTION=Y install_apache
            searxng.apache.install
            searxng.apache.activate
            ;;
        *)
            info_msg "No HTTP site installed.  Don't forget to install one."
            ;;
    esac
}

searxng.remove.all() {
    rst_title "De-Install SearXNG (service)"
    rst_para "\
This removes: the web server site(s), the uWSGI app, a local valkey/redis
server installed by this script, the service user ${SERVICE_USER} with
${SERVICE_HOME}, ${SEARXNG_SETTINGS_PATH} and (after separate confirmation)
OS packages.  Packages that other software may need are asked one by one."
    if ! ask_yn "Do you really want to deinstall SearXNG?"; then
        return
    fi
    cd / || true

    searxng.remove.sites
    searxng.remove.uwsgi
    searxng.remove.valkey
    searxng.remove.redis

    if getent passwd "${SERVICE_USER}" >/dev/null; then
        drop_service_account "${SERVICE_USER}"
    else
        info_msg "user ${SERVICE_USER} does not exist"
    fi
    searxng.remove.settings
    searxng.remove.misc
    searxng.remove.packages
    searxng.remove.package_leftovers
    searxng.remove.verify

    if service_is_available "${SEARXNG_URL}" &>/dev/null; then
        warn_msg "${SEARXNG_URL} still answers: another web server may proxy it, check its configuration"
    fi
    if ask_yn "Also delete this repository checkout (${REPO_ROOT})?"; then
        searxng.remove.repo
    fi
}

searxng.install.user() {
    rst_title "SearXNG -- install user" section
    echo
    if getent passwd "${SERVICE_USER}" >/dev/null; then
        echo "user already exists"
        return 0
    fi

    tee_stderr 1 <<EOF | bash | prefix_stdout
useradd --shell /bin/bash --system \
 --home-dir "${SERVICE_HOME}" \
 --comment 'Privacy-respecting metasearch engine' ${SERVICE_USER}
mkdir "${SERVICE_HOME}"
chown -R "${SERVICE_GROUP}:${SERVICE_GROUP}" "${SERVICE_HOME}"
groups ${SERVICE_USER}
EOF
}

searxng.install.packages() {
    TITLE="SearXNG -- install packages" pkg_install "${SEARXNG_PACKAGES}"
}

searxng.install.buildhost() {
    TITLE="SearXNG -- install buildhost packages" pkg_install \
        "${SEARXNG_PACKAGES} ${SEARXNG_BUILD_PACKAGES}"
}

searxng.install.clone() {
    rst_title "Clone SearXNG sources" section
    if ! service_account_is_available "${SERVICE_USER}"; then
        die 42 "To clone SearXNG, first install user ${SERVICE_USER}."
    fi
    echo
    if ! sudo -i -u "${SERVICE_USER}" ls -d "$REPO_ROOT" >/dev/null; then
        die 42 "user '${SERVICE_USER}' missed read permission: $REPO_ROOT"
    fi
    # SERVICE_HOME="$(sudo -i -u "${SERVICE_USER}" echo \$HOME 2>/dev/null)"
    if [[ ! "${SERVICE_HOME}" ]]; then
        err_msg "to clone SearXNG sources, user ${SERVICE_USER} hast to be created first"
        return 42
    fi
    if [[ ! $(git show-ref "refs/heads/${GIT_BRANCH}") ]]; then
        warn_msg "missing local branch ${GIT_BRANCH}"
        info_msg "create local branch ${GIT_BRANCH} from start point: origin/${GIT_BRANCH}"
        git branch "${GIT_BRANCH}" "origin/${GIT_BRANCH}"
    fi
    if [[ ! $(git rev-parse --abbrev-ref HEAD) == "${GIT_BRANCH}" ]]; then
        warn_msg "take into account, installing branch $GIT_BRANCH while current branch is $(git rev-parse --abbrev-ref HEAD)"
    fi
    # export SERVICE_HOME

    # clone repo and add a safe.directory entry to git's system config / see
    # https://github.com/searxng/searxng/issues/1251
    git config --system --add safe.directory "${REPO_ROOT}/.git"
    git_clone "$REPO_ROOT" "${SEARXNG_SRC}" \
        "$GIT_BRANCH" "${SERVICE_USER}"
    git config --system --add safe.directory "${SEARXNG_SRC}"

    pushd "${SEARXNG_SRC}" >/dev/null
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
cd "${SEARXNG_SRC}"
git remote set-url origin ${GIT_URL}
git config user.email "${ADMIN_EMAIL}"
git config user.name "${ADMIN_NAME}"
git config --list
EOF
    popd >/dev/null
}

searxng.install.link_src() {
    rst_title "link SearXNG's sources to: $2" chapter
    echo
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
mv -f "${SEARXNG_SRC}" "${SEARXNG_SRC}.backup"
ln -s "${2}" "${SEARXNG_SRC}"
ls -ld /usr/local/searxng/searxng-src
EOF
    echo
    uWSGI_restart "$SEARXNG_UWSGI_APP"
}

searxng.install.pyenv() {
    rst_title "Create virtualenv (python)" section
    echo
    if [[ ! -f "${SEARXNG_SRC}/manage" ]]; then
        die 42 "To create pyenv for SearXNG, first install searxng-src."
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        die 42 "python3 not found: install it with 'apt install python3 python3-venv python3-dev'"
    fi
    if ! python3 -c "import venv, ensurepip" >/dev/null 2>&1; then
        die 42 "python3 venv/ensurepip missing: install it with 'apt install python3-venv'"
    fi
    info_msg "create pyenv in ${SEARXNG_PYENV}"
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
rm -rf "${SEARXNG_PYENV}"
python3 -m venv "${SEARXNG_PYENV}"
grep -qFs -- 'source ${SEARXNG_PYENV}/bin/activate' ~/.profile \
  || echo 'source ${SEARXNG_PYENV}/bin/activate' >> ~/.profile
EOF
    if [[ ! -f "${SEARXNG_PYENV}/bin/activate" ]]; then
        die 42 "virtualenv was not created: ${SEARXNG_PYENV}/bin/activate is missing"
    fi
    info_msg "inspect python's virtual environment"
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
command -v python && python --version
EOF
    wait_key
    info_msg "install needed python packages"
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"

source "${SEARXNG_PYENV}/bin/activate"

# Install all required dependencies
pip install -U pip setuptools wheel pyyaml msgspec typing_extensions "numpy<2.0" httpx pygments whitenoise flask flask-babel markdown-it-py httpx-socks tomli valkey lxml python-dateutil typer isodate h2 fasttext

cd ${SEARXNG_SRC}
pip install --use-pep517 --no-build-isolation -e .
EOF
}

searxng.remove.pyenv() {
    rst_title "Remove virtualenv (python)" section
    if ! ask_yn "Do you really want to drop ${SEARXNG_PYENV} ?"; then
        return
    fi
    info_msg "remove pyenv activation from ~/.profile"
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
grep -v 'source ${SEARXNG_PYENV}/bin/activate' ~/.profile > ~/.profile.##
mv ~/.profile.## ~/.profile
EOF
    rm -rf "${SEARXNG_PYENV}"
}

searxng.install.settings() {
    rst_title "install ${SEARXNG_SETTINGS_PATH}" section

    if ! [[ -f "${SEARXNG_SRC}/.git/config" ]]; then
        die "Before install settings, first install SearXNG."
    fi

    mkdir -p "$(dirname "${SEARXNG_SETTINGS_PATH}")"

    DEFAULT_SELECT=1 \
        install_template --no-eval \
        "${SEARXNG_SETTINGS_PATH}" \
        "${SERVICE_USER}" "${SERVICE_GROUP}"

    tee_stderr 0.1 <<EOF | sudo -H -i 2>&1 | prefix_stdout "root"
sed -i -e "s/ultrasecretkey/$(openssl rand -hex 16)/g" "${SEARXNG_SETTINGS_PATH}"
EOF
}

searxng.remove.settings() {
    rst_title "remove ${SEARXNG_SETTINGS_PATH}" section
    if ask_yn "Do you want to delete the SearXNG settings?" Yn; then
        rm -f "${SEARXNG_SETTINGS_PATH}"
        local d
        d="$(dirname "${SEARXNG_SETTINGS_PATH}")"
        if [[ "$(basename "${d}")" == searxng ]]; then
            rm -rf "${d}"
        else
            rmdir --ignore-fail-on-non-empty "${d}" 2>/dev/null
        fi
    fi
}

searxng.check() {
    rst_title "SearXNG checks" section
    "${SEARXNG_PYENV}/bin/python" "${SEARXNG_SRC}/utils/searxng_check.py"
}

searxng.instance.update() {
    rst_title "Update SearXNG instance"
    rst_para "fetch from $GIT_URL and reset to origin/$GIT_BRANCH"
    tee_stderr 0.3 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
cd ${SEARXNG_SRC}
git fetch origin "$GIT_BRANCH"
git reset --hard "origin/$GIT_BRANCH"
pip install -U pip
pip install -U setuptools
pip install -U wheel
pip install -U pyyaml
pip install -U msgspec
pip install -U typing-extensions
pip install -U pybind11
pip install -U --use-pep517 --no-build-isolation -e .
EOF
    rst_para "update instance's settings.yml from ${SEARXNG_SETTINGS_PATH}"
    DEFAULT_SELECT=2 \
        install_template --no-eval \
        "${SEARXNG_SETTINGS_PATH}" \
        "${SERVICE_USER}" "${SERVICE_GROUP}"

    sudo -H -i <<EOF
sed -i -e "s/ultrasecretkey/$(openssl rand -hex 16)/g" "${SEARXNG_SETTINGS_PATH}"
EOF
    uWSGI_restart "${SEARXNG_UWSGI_APP}"
}

searxng.install.uwsgi() {
    rst_title "SearXNG (install uwsgi)"
    install_uwsgi
    if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
        searxng.install.uwsgi.socket
    else
        searxng.install.uwsgi.http
    fi
}

searxng.install.uwsgi.http() {
    rst_para "Install ${SEARXNG_UWSGI_APP} at: http://${SEARXNG_INTERNAL_HTTP}"
    uWSGI_install_app "${SEARXNG_UWSGI_APP}"
    if ! searxng.uwsgi.available; then
        err_msg "URL http://${SEARXNG_INTERNAL_HTTP} not available, check SearXNG & uwsgi setup!"
    fi
}

searxng.install.uwsgi.socket() {
    rst_para "Install ${SEARXNG_UWSGI_APP} using socket at: ${SEARXNG_UWSGI_SOCKET}"
    mkdir -p "$(dirname "${SEARXNG_UWSGI_SOCKET}")"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$(dirname "${SEARXNG_UWSGI_SOCKET}")"

    case $DIST_ID-$DIST_VERS in
        fedora-*)
            # Fedora runs uWSGI in emperor-tyrant mode: in Tyrant mode the
            # Emperor will run the vassal using the UID/GID of the vassal
            # configuration file [1] (user and group of the app .ini file).
            # [1] https://uwsgi-docs.readthedocs.io/en/latest/Emperor.html#tyrant-mode-secure-multi-user-hosting
            uWSGI_install_app --variant=socket "${SEARXNG_UWSGI_APP}" "${SERVICE_USER}" "${SERVICE_GROUP}"
            ;;
        *)
            uWSGI_install_app --variant=socket "${SEARXNG_UWSGI_APP}"
            ;;
    esac
    sleep 5
    if ! searxng.uwsgi.available; then
        err_msg "uWSGI socket not available at: ${SEARXNG_UWSGI_SOCKET}"
    fi
}

searxng.uwsgi.available() {
    if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
        [[ -S "${SEARXNG_UWSGI_SOCKET}" ]]
        exit_val=$?
        if [[ $exit_val = 0 ]]; then
            info_msg "uWSGI socket is located at: ${SEARXNG_UWSGI_SOCKET}"
        fi
    else
        service_is_available "http://${SEARXNG_INTERNAL_HTTP}"
        exit_val=$?
    fi
    return "$exit_val"
}

searxng.remove.uwsgi() {
    rst_title "Remove SearXNG's uWSGI app (${SEARXNG_UWSGI_APP})" section
    echo
    uWSGI_remove_app "${SEARXNG_UWSGI_APP}"
}

searxng.install.valkey() {
    rst_title "SearXNG (install valkey)"
    valkey.install
}

searxng.instance.localtest() {
    rst_title "Test SearXNG instance locally" section
    rst_para "Activate debug mode, start a minimal SearXNG " \
        "service and debug a HTTP request/response cycle."

    if service_is_available "http://${SEARXNG_INTERNAL_HTTP}" &>/dev/null; then
        err_msg "URL/port http://${SEARXNG_INTERNAL_HTTP} is already in use, you"
        err_msg "should stop that service before starting local tests!"
        if ! ask_yn "Continue with local tests?"; then
            return
        fi
    fi
    echo
    searxng.instance.debug.on
    tee_stderr 0.1 <<EOF | sudo -H -u "${SERVICE_USER}" -i 2>&1 | prefix_stdout "$_service_prefix"
export SEARXNG_SETTINGS_PATH="${SEARXNG_SETTINGS_PATH}"
cd ${SEARXNG_SRC}
timeout 15 python -m searx.webapp &
sleep 6
curl --location --verbose --head --insecure ${SEARXNG_INTERNAL_HTTP}
EOF
    echo
    searxng.instance.debug.off
}

searxng.install.http.pre() {
    if ! searxng.uwsgi.available; then
        rst_para "\
To install uWSGI use::

    $(basename "$0") install uwsgi
"
        die 42 "SearXNG's uWSGI app not available"
    fi

    if ! searxng.instance.exec python -c "from searx import valkeydb; valkeydb.initialize() or exit(42)"; then
        rst_para "\
The configured valkey DB is not available: If your server is public to the
internet, you should setup a bot protection to block excessively bot queries.
Bot protection requires a valkey DB.  About bot protection visit the official
SearXNG documentation and query for the word 'limiter'.
"
    fi
}

searxng.apache.install() {
    rst_title "Install Apache site ${APACHE_SEARXNG_SITE}"
    rst_para "\
This installs SearXNG's uWSGI app as apache site.  The apache site is located at:
${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}."
    searxng.install.http.pre

    if ! apache_is_installed; then
        err_msg "Apache packages are not installed"
        if ! ask_yn "Do you really want to continue and install apache packages?" Yn; then
            return
        else
            FORCE_SELECTION=Y install_apache
        fi
    else
        info_msg "Apache packages are installed [OK]"
    fi

    if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
        apache_install_site --variant=socket "${APACHE_SEARXNG_SITE}"
    else
        apache_install_site "${APACHE_SEARXNG_SITE}"
    fi

    if ! service_is_available "${SEARXNG_URL}"; then
        err_msg "Public service at ${SEARXNG_URL} is not available!"
    fi
}

searxng.apache.remove() {
    rst_title "Remove Apache site ${APACHE_SEARXNG_SITE}"
    rst_para "\
This removes apache site ${APACHE_SEARXNG_SITE}::

  ${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}"

    ! apache_is_installed && err_msg "Apache is not installed."
    if ! ask_yn "Do you really want to continue?" Yn; then
        return
    fi
    apache_remove_site "${APACHE_SEARXNG_SITE}"
}

searxng.nginx.install() {

    rst_title "Install nginx site ${NGINX_SEARXNG_SITE}"
    rst_para "\
This installs SearXNG's uWSGI app as Nginx site.  The Nginx site is located at:
${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE} and requires a uWSGI."
    searxng.install.http.pre

    if ! nginx_is_installed; then
        err_msg "Nginx packages are not installed"
        if ! ask_yn "Do you really want to continue and install Nginx packages?" Yn; then
            return
        else
            FORCE_SELECTION=Y install_nginx
        fi
    else
        info_msg "Nginx packages are installed [OK]"
    fi

    if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
        nginx_install_app --variant=socket "${NGINX_SEARXNG_SITE}"
    else
        nginx_install_app "${NGINX_SEARXNG_SITE}"
    fi

    if ! service_is_available "${SEARXNG_URL}"; then
        err_msg "Public service at ${SEARXNG_URL} is not available!"
    fi
}

searxng.nginx.remove() {
    rst_title "Remove Nginx site ${NGINX_SEARXNG_SITE}"
    rst_para "\
This removes Nginx site ${NGINX_SEARXNG_SITE}::

  ${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}"

    ! nginx_is_installed && err_msg "Nginx is not installed."
    if ! ask_yn "Do you really want to continue?" Yn; then
        return
    fi
    nginx_remove_app "${NGINX_SEARXNG_SITE}"
}

searxng.instance.exec() {
    if ! service_account_is_available "${SERVICE_USER}"; then
        die 42 "can't execute: instance does not exist (missed account ${SERVICE_USER})"
    fi
    sudo -H -i -u "${SERVICE_USER}" \
        SEARXNG_UWSGI_USE_SOCKET="${SEARXNG_UWSGI_USE_SOCKET}" \
        "$@"
}

searxng.instance.self.call() {
    # wrapper to call a function in instance's environment
    info_msg "wrapper:  utils/searxng.sh instance _call $*"
    searxng.instance.exec "${SEARXNG_SRC}/utils/searxng.sh" instance _call "$@"
}

searxng.instance.get_setting() {
    searxng.instance.exec python <<EOF
from searx import get_setting
print(get_setting('$1'))
EOF
}

searxng.instance.debug.on() {
    warn_msg "Do not enable debug in a production environment!"
    info_msg "try to enable debug mode ..."
    tee_stderr 0.1 <<EOF | sudo -H -i 2>&1 | prefix_stdout "$_service_prefix"
cd ${SEARXNG_SRC}
sed -i -e "s/debug: false/debug: true/g" "$SEARXNG_SETTINGS_PATH"
EOF
    uWSGI_restart "$SEARXNG_UWSGI_APP"
}

searxng.instance.debug.off() {
    info_msg "try to disable debug mode ..."
    tee_stderr 0.1 <<EOF | sudo -H -i 2>&1 | prefix_stdout "$_service_prefix"
cd ${SEARXNG_SRC}
sed -i -e "s/debug: true/debug: false/g" "$SEARXNG_SETTINGS_PATH"
EOF
    uWSGI_restart "$SEARXNG_UWSGI_APP"
}

searxng.instance.inspect() {
    rst_title "Inspect SearXNG instance"
    echo

    searxng.instance.self.call _searxng.instance.inspect

    local _debug_on
    if ask_yn "Enable SearXNG debug mode?"; then
        searxng.instance.debug.on
        _debug_on=1
    fi
    echo

    case $DIST_ID-$DIST_VERS in
        ubuntu-* | debian-*|linuxmint-*)
            # For uWSGI debian uses the LSB init process; for each configuration
            # file new uWSGI daemon instance is started with additional option.
            service uwsgi status "${SERVICE_NAME}"
            ;;
        arch-*)
            systemctl --no-pager -l status "uwsgi@${SERVICE_NAME%.*}"
            ;;
        fedora-*)
            systemctl --no-pager -l status uwsgi
            ;;
    esac

    echo -e "// use ${_BCyan}CTRL-C${_creset} to stop monitoring the log"
    read -r -s -n1 -t 5
    echo

    while true; do
        trap break 2
        case $DIST_ID-$DIST_VERS in
            ubuntu-* | debian-*|linuxmint-*) tail -f "/var/log/uwsgi/app/${SERVICE_NAME%.*}.log" ;;
            arch-*) journalctl -f -u "uwsgi@${SERVICE_NAME%.*}" ;;
            fedora-*) journalctl -f -u uwsgi ;;
        esac
    done

    if [[ $_debug_on == 1 ]]; then
        searxng.instance.debug.off
    fi
    return 0
}

_searxng.instance.inspect() {
    searxng.instance.env

    MSG="${_Green}[${_BCyan}CTRL-C${_Green}] to stop or [${_BCyan}KEY${_Green}] to continue${_creset}"

    if ! searxng.uwsgi.available; then
        err_msg "SearXNG's uWSGI app not available"
        wait_key
    fi
    if ! service_is_available "${SEARXNG_URL}"; then
        err_msg "Public service at ${SEARXNG_URL} is not available!"
        wait_key
    fi
}

searxng.doc.rst() {

    local APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
    local NGINX_APPS_AVAILABLE="/etc/nginx/default.apps-available"

    local debian="${SEARXNG_PACKAGES_debian}"
    local arch="${SEARXNG_PACKAGES_arch}"
    local fedora="${SEARXNG_PACKAGES_fedora}"
    local debian_build="${SEARXNG_BUILD_PACKAGES_debian}"
    local arch_build="${SEARXNG_BUILD_PACKAGES_arch}"
    local fedora_build="${SEARXNG_BUILD_PACKAGES_fedora}"
    debian="$(echo "${debian}" | sed 's/.*/          & \\/' | sed '$ s/.$//')"
    arch="$(echo "${arch}" | sed 's/.*/          & \\/' | sed '$ s/.$//')"
    fedora="$(echo "${fedora}" | sed 's/.*/          & \\/' | sed '$ s/.$//')"
    debian_build="$(echo "${debian_build}" | sed 's/.*/          & \\/' | sed '$ s/.$//')"
    arch_build="$(echo "${arch_build}" | sed 's/.*/          & \\/' | sed '$ s/.$//')"
    fedora_build="$(echo "${fedora_build}" | sed 's/.*/          & \\/' | sed '$ s/.$//')"

    if [[ ${SEARXNG_UWSGI_USE_SOCKET} == true ]]; then
        uwsgi_variant=':socket'
    else
        uwsgi_variant=':socket'
    fi

    eval "echo \"$(<"${REPO_ROOT}/docs/build-templates/searxng.rst")\""

    # I use ubuntu-20.04 here to demonstrate that versions are also supported,
    # normally debian-* and ubuntu-* are most the same.

    for DIST_NAME in ubuntu-20.04 arch fedora; do
        (
            DIST_ID=${DIST_NAME%-*}
            DIST_VERS=${DIST_NAME#*-}
            [[ $DIST_VERS =~ $DIST_ID ]] && DIST_VERS=
            uWSGI_distro_setup

            echo -e "\n.. START searxng uwsgi-description $DIST_NAME"

            case $DIST_ID-$DIST_VERS in
                ubuntu-* | debian-*|linuxmint-*)
                    cat <<EOF

.. code:: bash

   # init.d --> /usr/share/doc/uwsgi/README.Debian.gz
   # For uWSGI debian uses the LSB init process, this might be changed
   # one day, see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=833067

   create     ${uWSGI_APPS_AVAILABLE}/${SEARXNG_UWSGI_APP}
   enable:    sudo -H ln -s ${uWSGI_APPS_AVAILABLE}/${SEARXNG_UWSGI_APP} ${uWSGI_APPS_ENABLED}/
   start:     sudo -H service uwsgi start   ${SEARXNG_UWSGI_APP%.*}
   restart:   sudo -H service uwsgi restart ${SEARXNG_UWSGI_APP%.*}
   stop:      sudo -H service uwsgi stop    ${SEARXNG_UWSGI_APP%.*}
   disable:   sudo -H rm ${uWSGI_APPS_ENABLED}/${SEARXNG_UWSGI_APP}

EOF
                    ;;
                arch-*)
                    cat <<EOF

.. code:: bash

   # systemd --> /usr/lib/systemd/system/uwsgi@.service
   # For uWSGI archlinux uses systemd template units, see
   # - http://0pointer.de/blog/projects/instances.html
   # - https://uwsgi-docs.readthedocs.io/en/latest/Systemd.html#one-service-per-app-in-systemd

   create:    ${uWSGI_APPS_ENABLED}/${SEARXNG_UWSGI_APP}
   enable:    sudo -H systemctl enable   uwsgi@${SEARXNG_UWSGI_APP%.*}
   start:     sudo -H systemctl start    uwsgi@${SEARXNG_UWSGI_APP%.*}
   restart:   sudo -H systemctl restart  uwsgi@${SEARXNG_UWSGI_APP%.*}
   stop:      sudo -H systemctl stop     uwsgi@${SEARXNG_UWSGI_APP%.*}
   disable:   sudo -H systemctl disable  uwsgi@${SEARXNG_UWSGI_APP%.*}

EOF
                    ;;
                fedora-* | centos-7)
                    cat <<EOF

.. code:: bash

   # systemd --> /usr/lib/systemd/system/uwsgi.service
   # The unit file starts uWSGI in emperor mode (/etc/uwsgi.ini), see
   # - https://uwsgi-docs.readthedocs.io/en/latest/Emperor.html

   create:    ${uWSGI_APPS_ENABLED}/${SEARXNG_UWSGI_APP}
   restart:   sudo -H touch ${uWSGI_APPS_ENABLED}/${SEARXNG_UWSGI_APP}
   disable:   sudo -H rm ${uWSGI_APPS_ENABLED}/${SEARXNG_UWSGI_APP}

EOF
                    ;;
            esac
            echo -e ".. END searxng uwsgi-description $DIST_NAME"

            local _show_cursor="" # prevent from prefix_stdout's trailing show-cursor

            echo -e "\n.. START searxng uwsgi-appini $DIST_NAME"
            echo ".. code:: bash"
            echo
            eval "echo \"$(<"${TEMPLATES}/${uWSGI_APPS_AVAILABLE}/${SEARXNG_UWSGI_APP}${uwsgi_variant}")\"" | prefix_stdout "  "
            echo -e "\n.. END searxng uwsgi-appini $DIST_NAME"

            echo -e "\n.. START nginx socket"
            echo ".. code:: nginx"
            echo
            eval "echo \"$(<"${TEMPLATES}/${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}:socket")\"" | prefix_stdout "  "
            echo -e "\n.. END nginx socket"

            echo -e "\n.. START nginx http"
            echo ".. code:: nginx"
            echo
            eval "echo \"$(<"${TEMPLATES}/${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}")\"" | prefix_stdout "  "
            echo -e "\n.. END nginx http"

            echo -e "\n.. START apache socket"
            echo ".. code:: apache"
            echo
            eval "echo \"$(<"${TEMPLATES}/${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}:socket")\"" | prefix_stdout "  "
            echo -e "\n.. END apache socket"

            echo -e "\n.. START apache http"
            echo ".. code:: apache"
            echo
            eval "echo \"$(<"${TEMPLATES}/${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}")\"" | prefix_stdout "  "
            echo -e "\n.. END apache http"
        )
    done

}

# ==============================================================================
# Helpers (patched): choices, package handling, web server activation, verify
# Every removal of a package that is not exclusively SearXNG's is confirmed.
# ==============================================================================

# _ask_choice <prompt> <option>...   -> result in ${CHOICE}
_ask_choice() {
    local prompt="$1" i ans
    shift
    local opts=("$@")
    while true; do
        echo
        echo -e "${prompt}"
        for i in "${!opts[@]}"; do
            echo "  $((i + 1))) ${opts[$i]}"
        done
        if ! read -r -p "Choose [1-${#opts[@]}] (default 1): " ans; then
            # no terminal (EOF): take the last option, which is always 'none'
            CHOICE="${opts[$((${#opts[@]} - 1))]}"
            return 0
        fi
        ans="${ans:-1}"
        if [[ ${ans} =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#opts[@]})); then
            CHOICE="${opts[$((ans - 1))]}"
            return 0
        fi
        warn_msg "invalid choice: ${ans}"
    done
}

_pkg_family() {
    case "${DIST_ID}" in
        ubuntu | debian | linuxmint) echo apt ;;
        arch) echo pacman ;;
        fedora) echo dnf ;;
        *) if command -v apt-get >/dev/null 2>&1; then echo apt; else echo unknown; fi ;;
    esac
}

_pkg_is_installed() {
    case "$(_pkg_family)" in
        apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
        pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
        dnf) rpm -q "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# print the installed packages out of the given list
_pkg_filter_installed() {
    local p
    for p in "$@"; do
        _pkg_is_installed "$p" && echo "$p"
    done
    return 0
}

# Show what a purge would remove besides the requested packages (apt only).
# Returns 1 when OTHER packages would be removed too.
# NOTE: 'apt-get -s purge' prints "Purg <pkg>" lines ("Remv" only for remove).
_pkg_simulate() {
    [[ "$(_pkg_family)" == apt ]] || return 0
    local removed p extra=()
    removed="$(apt-get -s purge "$@" 2>/dev/null | awk '/^(Remv|Purg) /{print $2}' | sed 's/:.*$//')"
    for p in ${removed}; do
        [[ " $* " == *" ${p} "* ]] || extra+=("${p}")
    done
    if ((${#extra[@]})); then
        warn_msg "these OTHER packages depend on them and would be removed too:"
        echo "    ${extra[*]}"
        return 1
    fi
    info_msg "simulation: no other packages are affected"
    return 0
}

_pkg_purge() {
    case "$(_pkg_family)" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" ;;
        pacman) pacman -Rns --noconfirm "$@" ;;
        dnf) dnf remove -y "$@" ;;
    esac
}

# searxng.remove.packages.group <title> <Yn|""> <warning> <pkg>...
#   default answer is NO unless the second argument is 'Yn'
searxng.remove.packages.group() {
    local title="$1" default="$2" warning="$3" pkgs=()
    shift 3
    mapfile -t pkgs < <(_pkg_filter_installed "$@")
    if ((${#pkgs[@]} == 0)); then
        info_msg "${title}: none of these packages is installed"
        return 0
    fi
    rst_title "${title}" section
    rst_para "${warning}"
    info_msg "installed: ${pkgs[*]}"
    if ! _pkg_simulate "${pkgs[@]}"; then
        local typed=""
        read -r -p "Other software depends on these. Type 'yes' to purge anyway, anything else keeps them: " typed
        if [[ ${typed} == yes ]]; then
            _pkg_purge "${pkgs[@]}"
            return 0
        fi
        info_msg "kept: ${pkgs[*]}"
        return 1
    fi
    if ask_yn "Purge these packages?" ${default:+"${default}"}; then
        _pkg_purge "${pkgs[@]}"
        return 0
    fi
    info_msg "kept: ${pkgs[*]}"
    return 1
}

_nginx_other_sites() {
    local f
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [[ -e ${f} ]] || continue
        case "$(basename "${f}")" in
            default | default.conf | searxng*) ;;
            *) echo "${f}" ;;
        esac
    done
}

_uwsgi_other_apps() {
    local f
    for f in "${uWSGI_APPS_ENABLED}"/*.ini; do
        [[ -e ${f} ]] || continue
        [[ "$(basename "${f}")" == "${SEARXNG_UWSGI_APP}" ]] && continue
        echo "${f}"
    done
}

searxng.remove.packages() {
    rst_title "Remove OS packages" section
    rst_para "\
The following packages may be used by other software on this host.  Each group
is confirmed separately and the package manager is simulated first so you can
see what else would be removed.  When in doubt answer 'no'."

    if [[ "$(_pkg_family)" == unknown ]]; then
        warn_msg "unsupported package manager: remove packages manually"
        return 0
    fi

    local p all=() uw=() gen=() kv=() web=() others
    mapfile -t all < <(echo ${SEARXNG_PACKAGES} | tr -s ' \n' '\n' | awk '!seen[$0]++')
    for p in "${all[@]}"; do
        case "${p}" in
            uwsgi*) uw+=("${p}") ;;
            git) ;; # never offered: needed to clone/update your fork
            *) gen+=("${p}") ;;
        esac
    done

    # uWSGI ------------------------------------------------------------------
    others="$(_uwsgi_other_apps)"
    uw+=(uwsgi-core uwsgi-emperor)
    if [[ -n ${others} ]]; then
        searxng.remove.packages.group "uWSGI" "" \
            "uWSGI still runs OTHER apps (answer 'no'):
${others}" "${uw[@]}"
    else
        searxng.remove.packages.group "uWSGI" Yn \
            "No other uWSGI apps are enabled, uWSGI was installed for SearXNG." "${uw[@]}"
    fi

    # web servers ------------------------------------------------------------
    others="$(_nginx_other_sites)"
    case "$(_pkg_family)" in
        apt) web=(nginx nginx-common nginx-core nginx-light nginx-full) ;;
        *) web=(nginx) ;;
    esac
    searxng.remove.packages.group "nginx" "" \
        "nginx is a general purpose web server.${others:+
OTHER sites are configured, DO NOT remove it:
${others}}" "${web[@]}"

    case "$(_pkg_family)" in
        apt) web=(apache2 apache2-bin apache2-data apache2-utils libapache2-mod-proxy-uwsgi) ;;
        pacman) web=(apache) ;;
        *) web=(httpd) ;;
    esac
    local other_apache=""
    if [[ -d ${APACHE_SITES_ENABLED} ]]; then
        other_apache="$(find "${APACHE_SITES_ENABLED}" -mindepth 1 ! -name '000-default.conf' ! -name 'searxng*' 2>/dev/null)"
    fi
    searxng.remove.packages.group "apache" "" \
        "apache is a general purpose web server.${other_apache:+
OTHER sites are configured, DO NOT remove it:
${other_apache}}" "${web[@]}"

    # generic build / runtime packages ---------------------------------------
    searxng.remove.packages.group "generic python / build packages" "" \
        "These are common development packages (git, compilers, python headers,
-dev libraries) that many other programs and your desktop may need.
SearXNG's installer pulled them in, but removing them is usually NOT wanted." \
        "${gen[@]}"

    # orphans (apt only) -----------------------------------------------------
    if [[ "$(_pkg_family)" == apt ]]; then
        local orphans
        orphans="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' | tr '\n' ' ')"
        if [[ -n ${orphans// /} ]]; then
            rst_title "Unused dependencies" section
            info_msg "apt reports these packages as no longer needed:"
            echo "  ${orphans}"
            if ask_yn "Run 'apt-get autoremove --purge' now?"; then
                DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
            fi
        fi
    fi
}

# install: git/curl/wget are required, install them if they are missing
searxng.ensure_tools() {
    local c missing=()
    for c in git wget curl; do
        command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
    done
    ((${#missing[@]})) || return 0
    if [[ "$(id -u)" -ne 0 ]]; then
        return 0 # required_commands reports it; installing needs root
    fi
    TITLE="SearXNG -- install missing tools (${missing[*]})" pkg_install "${missing[@]}"
}

searxng.remove.package_leftovers() {
    rst_title "Clean package leftovers" section
    if ! _pkg_is_installed uwsgi && ! _pkg_is_installed uwsgi-core; then
        rm -rf /run/uwsgi
        if [[ -f /etc/apparmor.d/uwsgi-core ]]; then
            rm -f /etc/apparmor.d/uwsgi-core /var/cache/apparmor/*/uwsgi-core
            info_msg "removed the apparmor profile left behind by uwsgi-core"
        fi
    fi
    if [[ "$(_pkg_family)" == apt ]] && ask_yn "Clear the APT package cache (apt-get clean)?" Yn; then
        apt-get clean
    fi
}

# _searxng.remove.kv <valkey|redis> <script-home> <pkg>...
#   1) a server built below <script-home> (older installers), 2) distribution
#   packages (valkey.install in lib_valkey.sh uses apt: valkey-server)
_searxng.remove.kv() {
    local name="$1" home="$2" f u d found=0
    shift 2
    local units=("${name}" "${name}-server")
    local unit_dirs=(/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system)

    if [[ -n ${home} ]]; then
        [[ -d ${home} ]] && found=1
        if ((found)); then
            rst_title "Remove local ${name} server (${home})" section
            if ask_yn "Remove the ${name} server installed in ${home}?" Yn; then
                for u in "${units[@]}"; do systemctl disable --now "${u}.service" 2>/dev/null; done
                for d in "${unit_dirs[@]}"; do
                    for u in "${units[@]}"; do
                        f="${d}/${u}.service"
                        if [[ -f ${f} ]] && grep -q "${home}" "${f}" 2>/dev/null; then rm -f "${f}"; fi
                    done
                done
                systemctl daemon-reload
                rm -rf "${home}"
                info_msg "removed ${home}"
            fi
        fi
    fi

    # distribution packages (confirmed, default NO: other software may use it)
    if searxng.remove.packages.group "${name} (distribution packages)" "" \
        "Other software (caches, queues, web apps ...) may use ${name}.
Only remove it if it was installed for SearXNG." "$@"; then
        for u in "${units[@]}"; do
            systemctl disable --now "${u}.service" 2>/dev/null
        done
        systemctl daemon-reload
        if getent passwd "${name}" >/dev/null && ask_yn "Also delete the system user '${name}'?"; then
            userdel "${name}" 2>/dev/null
            getent group "${name}" >/dev/null && groupdel "${name}" 2>/dev/null
        fi
    fi
}

searxng.remove.valkey() {
    rst_title "SearXNG (remove valkey)"
    _searxng.remove.kv valkey "${VALKEY_HOME:-}" valkey-server valkey-tools valkey

    # valkey.backports (lib_valkey.sh) installs an extra APT source
    local f
    for f in /etc/apt/sources.list.d/debian-stable-backports.sources \
        /etc/apt/sources.list.d/ubuntu-stable-backports.sources; do
        if [[ -f ${f} ]]; then
            warn_msg "found ${f} (added by the valkey installer when the package was not in your repos)"
            if ask_yn "Remove this APT source and run 'apt update'?"; then
                rm -f "${f}"
                apt-get update >/dev/null 2>&1
            fi
        fi
    done
}

searxng.remove.redis() {
    rst_title "SearXNG (remove redis)"
    _searxng.remove.kv redis "${REDIS_HOME:-}" redis-server redis-tools redis
}

searxng.remove.sites() {
    rst_title "Remove web server sites" section

    # nginx
    searxng.remove.https
    if nginx_is_installed; then
        if [[ -e "${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}" ||
            -L "${NGINX_APPS_ENABLED}/${NGINX_SEARXNG_SITE}" ]]; then
            nginx_remove_app "${NGINX_SEARXNG_SITE}"
        fi
    fi
    rm -f "${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}" \
        "${NGINX_APPS_ENABLED}/${NGINX_SEARXNG_SITE}"
    # lib.sh (nginx_include_apps_enabled) added 'include ${NGINX_APPS_ENABLED}/*.conf;'
    # to the default server.  Undo that, but never on fedora/centos (stock directive)
    # and never while other apps still use the folder.
    local f
    if [[ "$(_pkg_family)" != dnf ]] && ! compgen -G "${NGINX_APPS_ENABLED}/*.conf" >/dev/null; then
        for f in "${NGINX_DEFAULT_SERVER}" /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf; do
            [[ -f ${f} ]] || continue
            if grep -q "include ${NGINX_APPS_ENABLED}/\*\.conf;" "${f}" &&
                { [[ -f "${f}.bak" ]] || [[ -f "${f}.searxng.bak" ]] || grep -q 'added by searxng.sh' "${f}"; }; then
                sed -i \
                    -e "\|^[[:space:]]*include ${NGINX_APPS_ENABLED}/\*\.conf;|d" \
                    -e '/# Load configuration files for the default server block\./d' \
                    -e '/# added by searxng\.sh/d' "${f}"
                rm -f "${f}.bak" "${f}.searxng.bak"
                info_msg "removed include of ${NGINX_APPS_ENABLED} from ${f}"
            fi
        done
    fi
    if nginx_is_installed && nginx -t >/dev/null 2>&1; then
        nginx_reload
    fi

    # apache
    if apache_is_installed; then
        if [[ -e "${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}" ]]; then
            apache_remove_site "${APACHE_SEARXNG_SITE}"
        fi
        if command -v a2dissite >/dev/null 2>&1; then
            a2dissite "${APACHE_SEARXNG_SITE%.conf}" >/dev/null 2>&1
        fi
    fi
    rm -f "${APACHE_SITES_AVAILABLE}/${APACHE_SEARXNG_SITE}" \
        "${APACHE_SITES_ENABLED}/${APACHE_SEARXNG_SITE}"
    if apache_is_installed; then
        systemctl reload apache2 2>/dev/null || systemctl reload httpd 2>/dev/null
    fi
    return 0
}

searxng.remove.misc() {
    rst_title "Remove remaining SearXNG files" section
    local d re
    # git safe.directory entries added by searxng.install.clone
    for d in "${SEARXNG_SRC}" "${SERVICE_HOME}" "${SERVICE_HOME}/.git"; do
        re="^$(printf '%s' "${d}" | sed 's/[][\.*^$/]/\\&/g')\$"
        git config --system --unset-all safe.directory "${re}" 2>/dev/null
    done
    # uWSGI app files and logs (idempotent, in case the lib left something)
    rm -f "${uWSGI_APPS_AVAILABLE}/${SEARXNG_UWSGI_APP}" \
        "${uWSGI_APPS_ENABLED}/${SEARXNG_UWSGI_APP}"
    rm -f /var/log/uwsgi/app/"${SERVICE_NAME}".log*
    systemctl disable --now "uwsgi@${SERVICE_NAME}" 2>/dev/null
    if [[ -d ${SERVICE_HOME} ]]; then
        warn_msg "${SERVICE_HOME} still exists"
        if ask_yn "Delete ${SERVICE_HOME}?" Yn; then
            rm -rf "${SERVICE_HOME}"
        fi
    fi
    if getent group "${SERVICE_GROUP}" >/dev/null; then
        groupdel "${SERVICE_GROUP}" 2>/dev/null
    fi
}

# Delete the repository checkout (ask first, warn about unsaved work)
searxng.remove.repo() {
    rst_title "Remove repository checkout" section
    local repo="${REPO_ROOT}" dirty unpushed
    case "${repo}" in
        "" | / | /usr | /usr/local | /home | /etc | /root | "${HOME}")
            err_msg "refusing to delete '${repo}'"
            return 1
            ;;
    esac
    dirty="$(git -c safe.directory='*' -C "${repo}" status --porcelain 2>/dev/null)"
    unpushed="$(git -c safe.directory='*' -C "${repo}" log --oneline '@{u}..' 2>/dev/null)"
    if [[ -n ${dirty} ]]; then
        warn_msg "UNCOMMITTED changes would be lost (this includes a patched searxng.sh):"
        echo "${dirty}" | head -n 15
    fi
    if [[ -n ${unpushed} ]]; then
        warn_msg "UNPUSHED commits would be lost:"
        echo "${unpushed}" | head -n 15
    fi
    if ask_yn "Delete ${repo} (you can re-clone your fork afterwards)?"; then
        cd / || true
        rm -rf "${repo}"
        info_msg "deleted ${repo}"
        exit 0
    fi
}

# Look for anything that is left behind
searxng.remove.verify() {
    rst_title "Verify: look for leftovers" section
    local out left=0 u

    local prune=(-path /proc -o -path /sys -o -path /dev -o -path /mnt -o -path /media -o -path /snap
        -o -path /var/lib/docker -o -path /var/lib/containerd -o -path /var/lib/snapd
        -o -path '*/.local/share/Trash' -o -name node_modules -o -path /usr/share/icons)
    local sysdirs=(/etc /usr /opt /var /run /lib /bin /sbin /srv /root)
    local sysout homeout
    # searxng / uwsgi / valkey anywhere, redis only in system locations
    out="$(find / \( "${prune[@]}" \) -prune -o \
        \( -iname '*searx*' -o -iname '*valkey*' -o -iname '*uwsgi*' \) \
        -not -path "${REPO_ROOT}" -not -path "${REPO_ROOT}/*" \
        -not -path '*/dist-packages/*' -not -path '*/site-packages/*' -not -name '*.svg' \
        -print 2>/dev/null)"
    out+=$'\n'"$(find "${sysdirs[@]}" \( "${prune[@]}" \) -prune -o \
        \( -name redis -o -name 'redis-*' -o -name 'redis.*' -o -name 'redis_*' \) \
        -not -path '*/dist-packages/*' -not -path '*/site-packages/*' -not -name '*.svg' \
        -not -path '/usr/share/*' -print 2>/dev/null)"
    sysout="$(echo "${out}" | grep -v '^$' | grep -v '^/home/' | grep -v '^/var/cache/apt/archives/')"
    homeout="$(echo "${out}" | grep '^/home/')"
    if [[ -n ${sysout} ]]; then
        warn_msg "system files / directories still present:"
        echo "${sysout}" | sed 's/^/    /'
        left=1
    else
        info_msg "system files: nothing found"
    fi
    if [[ -n ${homeout} ]]; then
        info_msg "in home directories (your own files, not counted as leftovers):"
        echo "${homeout}" | head -n 20 | sed 's/^/    /'
    fi

    for u in searxng valkey redis; do
        if getent passwd "${u}" >/dev/null; then warn_msg "user still exists: ${u}"; left=1; fi
        if getent group "${u}" >/dev/null; then warn_msg "group still exists: ${u}"; left=1; fi
    done

    case "$(_pkg_family)" in
        apt) out="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /uwsgi|valkey|redis|searx|^nginx|^apache2/ {print $2}')" ;;
        pacman) out="$(pacman -Qq 2>/dev/null | grep -E 'uwsgi|valkey|redis|searx|nginx|apache')" ;;
        dnf) out="$(rpm -qa 2>/dev/null | grep -E 'uwsgi|valkey|redis|searx|nginx|httpd')" ;;
        *) out="" ;;
    esac
    if [[ -n ${out} ]]; then
        warn_msg "packages still installed (fine if you chose to keep them):"
        echo "${out}" | sed 's/^/    /'
    else
        info_msg "packages: none of uwsgi / valkey / redis / nginx / apache installed"
    fi

    out="$(systemctl list-units --all --no-legend 2>/dev/null | grep -Ei 'uwsgi|valkey|redis|searx' | awk '{print $1}')"
    if [[ -n ${out} ]]; then
        warn_msg "systemd units still known:"
        echo "${out}" | sed 's/^/    /'
        left=1
    else
        info_msg "systemd: no uwsgi / valkey / redis / searxng units"
    fi

    out="$({ pgrep -a -x uwsgi; pgrep -a -x valkey-server; pgrep -a -x redis-server; pgrep -a -f 'searx\.webapp'; } 2>/dev/null)"
    if [[ -n ${out} ]]; then
        warn_msg "processes still running:"
        echo "${out}" | sed 's/^/    /'
        left=1
    else
        info_msg "processes: none running"
    fi

    out="$(ss -ltnpH 2>/dev/null | grep -E ':(8888|6379)\b')"
    if [[ -n ${out} ]]; then
        warn_msg "ports 8888 / 6379 still listening:"
        echo "${out}" | sed 's/^/    /'
        left=1
    else
        info_msg "ports 8888 / 6379: not listening"
    fi

    out="$(grep -rIl -i searxng /etc 2>/dev/null | grep -v -- '-$')"
    if [[ -n ${out} ]]; then
        warn_msg "/etc files still mentioning searxng:"
        echo "${out}" | sed 's/^/    /'
        left=1
    else
        info_msg "/etc: no file mentions searxng"
    fi

    if ((left)); then
        warn_msg "leftovers found (see above)"
    else
        info_msg "CLEAN: no SearXNG leftovers found"
    fi
}

# ==============================================================================
# Web server activation (install flow)
# ==============================================================================

# HTTP check against the local web server (does not depend on DNS).
# Any answer proves nginx/apache reached uWSGI: SearXNG's bot limiter answers
# curl with 429, which is fine.  Only 000 (no connection), 404 (site not
# routed) and 502/503/504 (uWSGI unreachable) count as failure.
#   usage: searxng.http.check [http|https] [host]      -> sets SEARXNG_HTTP_CODE
searxng.http.check() {
    local scheme="${1:-http}" host="${2:-$(uname -n)}"
    local path="${SEARXNG_URL_PATH%/}/" i code=000
    for i in 1 2 3 4 5 6; do
        code="$(curl -ks --max-time 8 -o /dev/null -w '%{http_code}' \
            -A 'Mozilla/5.0 (X11; Linux x86_64)' -H "Host: ${host}" \
            "${scheme}://127.0.0.1${path}")"
        case "${code}" in
            000 | 404 | 502 | 503 | 504) ;;
            *)
                SEARXNG_HTTP_CODE="${code}"
                return 0
                ;;
        esac
        sleep 2
    done
    SEARXNG_HTTP_CODE="${code}"
    return 1
}

_uwsgi_enable() {
    case "${DIST_ID}" in
        arch) systemctl enable --now "uwsgi@${SERVICE_NAME}" 2>/dev/null ;;
        *) systemctl enable --now uwsgi 2>/dev/null ;;
    esac
}

# make sure nginx includes ${NGINX_APPS_ENABLED}/*.conf inside a server block
_nginx_ensure_apps_include() {
    if nginx -T 2>/dev/null | grep -q "${NGINX_APPS_ENABLED}/${NGINX_SEARXNG_SITE}"; then
        info_msg "nginx loads ${NGINX_APPS_ENABLED}"
        return 0
    fi
    warn_msg "nginx does not load ${NGINX_APPS_ENABLED}: adding an include to the default server"
    local f target=""
    for f in /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf /etc/nginx/nginx.conf; do
        if [[ -f ${f} ]] && grep -Eq '^[[:space:]]*server_name' "${f}"; then
            target="${f}"
            break
        fi
    done
    if [[ -z ${target} ]]; then
        err_msg "no default nginx server block found: add 'include ${NGINX_APPS_ENABLED}/*.conf;' manually"
        return 1
    fi
    [[ -f "${target}.searxng.bak" ]] || cp -a "${target}" "${target}.searxng.bak"
    awk -v inc="    include ${NGINX_APPS_ENABLED}/*.conf;" '
        { print }
        !done && $0 ~ /^[ \t]*server_name/ { print "    # added by searxng.sh"; print inc; done = 1 }
    ' "${target}.searxng.bak" >"${target}"
    if ! nginx -t >/dev/null 2>&1; then
        err_msg "nginx -t failed after patching ${target}: restoring backup"
        cp -a "${target}.searxng.bak" "${target}"
        return 1
    fi
    info_msg "patched ${target} (backup: ${target}.searxng.bak, restored by 'remove')"
}

searxng.nginx.activate() {
    rst_title "Activate nginx site" section
    local site="${NGINX_APPS_AVAILABLE}/${NGINX_SEARXNG_SITE}"
    [[ -f ${site} ]] || die 42 "missing ${site}: nginx site was not installed"
    mkdir -p "${NGINX_APPS_ENABLED}"
    if [[ ! -e "${NGINX_APPS_ENABLED}/${NGINX_SEARXNG_SITE}" ]]; then
        ln -s "${site}" "${NGINX_APPS_ENABLED}/${NGINX_SEARXNG_SITE}"
    fi
    _nginx_ensure_apps_include
    if ! nginx -t; then
        die 42 "nginx configuration test failed"
    fi
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx || err_msg "nginx failed to start: is port 80 already in use?"
    _uwsgi_enable
    searxng.http.check.report nginx
}

searxng.apache.activate() {
    rst_title "Activate apache site" section
    local svc=apache2
    systemctl list-unit-files 2>/dev/null | grep -q '^apache2.service' || svc=httpd
    if command -v a2enmod >/dev/null 2>&1; then
        a2enmod proxy proxy_uwsgi proxy_http >/dev/null 2>&1
        a2ensite "${APACHE_SEARXNG_SITE%.conf}" >/dev/null 2>&1
    fi
    if command -v apachectl >/dev/null 2>&1 && ! apachectl configtest; then
        die 42 "apache configuration test failed"
    fi
    systemctl enable "${svc}" >/dev/null 2>&1
    systemctl restart "${svc}" || err_msg "${svc} failed to start: is port 80 already in use?"
    _uwsgi_enable
    searxng.http.check.report "${svc}"
}

searxng.http.check.report() {
    local svc="$1"
    if searxng.http.check http; then
        info_msg "SearXNG answers at ${SEARXNG_URL} (HTTP ${SEARXNG_HTTP_CODE}, via ${svc}) [OK]"
        [[ ${SEARXNG_HTTP_CODE} == 429 ]] &&
            info_msg "429 is SearXNG's bot limiter rejecting curl: a browser gets the page"
        return 0
    fi
    err_msg "no usable answer from http://127.0.0.1${SEARXNG_URL_PATH%/}/ (HTTP ${SEARXNG_HTTP_CODE})"
    systemctl --no-pager -l status "${svc}" 2>&1 | tail -n 8
    info_msg "last log lines (may include older entries):"
    tail -n 5 /var/log/nginx/error.log 2>/dev/null
    tail -n 5 /var/log/uwsgi/app/"${SERVICE_NAME}".log 2>/dev/null
    return 1
}

searxng.install.summary() {
    rst_title "Summary" section
    local s
    for s in uwsgi nginx apache2 httpd valkey valkey-server redis-server; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${s}.service"; then
            printf '  %-14s active: %-9s enabled at boot: %s\n' "${s}" \
                "$(systemctl is-active "${s}" 2>/dev/null)" "$(systemctl is-enabled "${s}" 2>/dev/null)"
        fi
    done
    echo
    echo "  settings : ${SEARXNG_SETTINGS_PATH}"
    echo "  URL      : ${SEARXNG_URL}"
    echo "  remove   : sudo -H ${REPO_ROOT}/utils/searxng.sh remove all"
}

# ----------------------------------------------------------------------------
main "$@"
# ----------------------------------------------------------------------------
