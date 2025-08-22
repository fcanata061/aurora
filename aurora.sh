#!/bin/sh
# Aurora Package Manager - Gerenciador de pacotes simples e funcional
# Autor: Você + ChatGPT
# Licença: MIT
# --------------------------------------------------------------

set -e

# Diretórios principais
: "${AURORA_ROOT:=/}"
: "${AURORA_DB:=/var/lib/aurora/db}"
: "${AURORA_LOG:=/var/log/aurora}"
: "${AURORA_REPO:=/var/lib/aurora/repo}"
: "${AURORA_CACHE:=/var/cache/aurora}"

mkdir -p "$AURORA_DB" "$AURORA_LOG" "$AURORA_REPO" "$AURORA_CACHE"

# --------------------------------------------------------------
# Funções utilitárias
# --------------------------------------------------------------

msg() {
    printf "\033[1;32m==>\033[0m %s\n" "$*"
}

err() {
    printf "\033[1;31m==>\033[0m ERRO: %s\n" "$*" >&2
    exit 1
}

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$AURORA_LOG/aurora.log"
}

spinner() {
    pid=$!
    spin='-\|/'
    i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%c] " "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r    \r"
}

# --------------------------------------------------------------
# Preparar ambiente de build
# --------------------------------------------------------------
prepare_build_env() {
    pkg="$1"
    work="$AURORA_CACHE/build/$pkg"
    rm -rf "$work"
    mkdir -p "$work/src" "$work/build" "$work/pkg"
    export srcdir="$work/src"
    export builddir="$work/build"
    export pkgdir="$work/pkg"
    export DESTDIR="$pkgdir"
    export PREFIX="/usr"
    export PATH="/usr/bin:/bin:$PATH"
    : "${CFLAGS:=-O2 -pipe}"
    export CXXFLAGS="$CFLAGS"
    : "${LDFLAGS:=-Wl,-O1}"
    export CFLAGS="$(printf %s "$CFLAGS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    export LDFLAGS="$(printf %s "$LDFLAGS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    export MAKEFLAGS="-j$(nproc)"
}

# --------------------------------------------------------------
# Configuração de repositório e caminho de receitas
# --------------------------------------------------------------
: "${AURORA_REPO_REMOTE:=}"   # ex: https://seu.git/aurora-repo.git
: "${AURORA_GIT_SYNC:=1}"
: "${AURORA_PATH:=$AURORA_REPO/core:$AURORA_REPO/extra:$AURORA_REPO/x11:$AURORA_REPO/desktop}"

[ -f /etc/aurora.conf ] && . /etc/aurora.conf

LOG_F="$AURORA_LOG/aurora-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_F"

need() { command -v "$1" >/dev/null 2>&1 || err "Falta dependência externa: $1"; }
need find; need sort; need awk; need sed; need tar
command -v sha256sum >/dev/null 2>&1 || err "Precisa do sha256sum"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || err "Instale curl ou wget"
command -v git >/dev/null 2>&1 || true
command -v unzip >/dev/null 2>&1 || true

# --------------------------------------------------------------
# Utilidades de arquivo/versão
# --------------------------------------------------------------
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
read_file(){ [ -f "$1" ] || return 1; cat "$1"; }

find_pkg_dir() {
    pkg="$1"
    IFS=:; for base in $AURORA_PATH; do
        [ -d "$base/$pkg" ] && { printf "%s\n" "$base/$pkg"; return 0; }
    done
    return 1
}

pkg_ver_repo(){ d="$(find_pkg_dir "$1")" || return 1; read_file "$d/version" | awk 'NF{print $1; exit}'; }
pkg_rel_repo(){ d="$(find_pkg_dir "$1")" || return 1; read_file "$d/version" | awk 'NF{print (NF>=2?$2:1); exit}'; }
pkg_ver_installed(){ [ -f "$AURORA_DB/$1/version" ] || return 1; cat "$AURORA_DB/$1/version"; }

ver_gt(){ a="$1"; b="$2"; printf "%s\n%s\n" "$a" "$b" | sort -V | tail -n1 | grep -qx "$a"; }

sha256_check(){
    file="$1"; want="$2"
    [ -f "$file" ] || err "Arquivo inexistente para checksum: $file"
    have="$(sha256sum "$file" | awk '{print $1}')"
    [ "$have" = "$want" ] || err "SHA256 inválido: $(basename "$file") esperado=$want obtido=$have"
}

download(){
    url="$1"; out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$out" "$url"
    else
        wget -O "$out" "$url"
    fi
}

detect_extract(){
    f="$1"; dest="$2"
    case "$f" in
        *.tar.gz|*.tgz) tar -xzf "$f" -C "$dest" ;;
        *.tar.xz)       tar -xJf "$f" -C "$dest" ;;
        *.tar.bz2)      tar -xjf "$f" -C "$dest" ;;
        *.tar.lz)       tar --lzip -xf "$f" -C "$dest" ;;
        *.tar.zst)      tar --zstd -xf "$f" -C "$dest" ;;
        *.zip)          command -v unzip >/dev/null 2>&1 || err "unzip não instalado"; unzip -q "$f" -d "$dest" ;;
        *)              err "Formato de arquivo desconhecido: $f" ;;
    esac
}

list_deps(){
    d="$1"
    [ -f "$d/depends" ] || return 0
    awk 'NF && $1 !~ /^#/ {print $1}' "$d/depends" | sort -u
}

resolve_deps_recursive(){
    target="$1"
    seen=""; order=""
    _dfs(){
        p="$1"
        case " $seen " in *" $p "*) return;; esac
        seen="$seen $p"
        dir="$(find_pkg_dir "$p")" || err "Pacote não encontrado no repo: $p"
        for dep in $(list_deps "$dir"); do _dfs "$dep"; done
        order="$order $p"
    }
    _dfs "$target"
    printf "%s\n" "$order" | awk 'NF{for(i=1;i<=NF;i++)print $i}'
}

dedup(){
    seen=""
    for w in "$@"; do
        case " $seen " in *" $w "*) : ;; *) seen="$seen $w"; printf "%s\n" "$w";;
        esac
    done
}


# --------------------------------------------------------------
# Resolver dependências recursivas
# --------------------------------------------------------------
resolve_deps() {
    pkg="$1"
    resolved=""
    stack="$pkg"

    while [ -n "$stack" ]; do
        cur="${stack%% *}"
        stack="${stack#* }"

        [ -f "$AURORA_REPO/$cur/aurora.build" ] || err "Pacote '$cur' não encontrado"

        deps=$(grep '^depends=' "$AURORA_REPO/$cur/aurora.build" | cut -d= -f2- | tr -d '"')
        for dep in $deps; do
            case " $resolved " in
                *" $dep "*) : ;;
                *) stack="$stack $dep" ;;
            esac
        done

        case " $resolved " in
            *" $cur "*) : ;;
            *) resolved="$resolved $cur" ;;
        esac
    done

    dedup $resolved
}

# --------------------------------------------------------------
# Build de um pacote
# --------------------------------------------------------------
build_pkg() {
    pkg="$1"
    msg "Iniciando build de $pkg"
    prepare_build_env "$pkg"

    buildfile="$AURORA_REPO/$pkg/aurora.build"
    [ -f "$buildfile" ] || err "Receita não encontrada: $pkg"

    (
        cd "$srcdir"
        . "$buildfile"
        fetch
        extract
        build
        package
    ) 2>&1 | tee -a "$AURORA_LOG/$pkg.log"
}

# --------------------------------------------------------------
# Instalar pacote
# --------------------------------------------------------------
install_pkg() {
    pkg="$1"
    tarball="$AURORA_CACHE/$pkg.tar.gz"

    [ -f "$tarball" ] || err "Pacote não compilado: $pkg"

    msg "Instalando $pkg"
    tar -xpf "$tarball" -C "$AURORA_ROOT"
    echo "$pkg" >> "$AURORA_DB/installed"
}

# --------------------------------------------------------------
# Remover pacote
# --------------------------------------------------------------
remove_pkg() {
    pkg="$1"

    grep -q "^$pkg$" "$AURORA_DB/installed" || err "Pacote não instalado: $pkg"

    msg "Removendo $pkg"
    # Registra antes de remover
    echo "$pkg" >> "$AURORA_LOG/removed.log"

    # Para simplificar: não temos lista de arquivos -> placeholder
    err "Remoção completa ainda não implementada (necessário registrar arquivos na instalação)"
}

# --------------------------------------------------------------
# Upgrade de pacotes (simples: recompila se houver versão maior)
# --------------------------------------------------------------
upgrade_pkg() {
    pkg="$1"
    buildfile="$AURORA_REPO/$pkg/aurora.build"
    [ -f "$buildfile" ] || err "Receita não encontrada: $pkg"

    newver=$(grep '^version=' "$buildfile" | cut -d= -f2- | tr -d '"')
    curver=$(grep "^$pkg " "$AURORA_DB/versions" | awk '{print $2}')

    if [ -z "$curver" ] || [ "$newver" \> "$curver" ]; then
        msg "Atualizando $pkg de $curver para $newver"
        build_pkg "$pkg"
        install_pkg "$pkg"
        sed -i "/^$pkg /d" "$AURORA_DB/versions"
        echo "$pkg $newver" >> "$AURORA_DB/versions"
    else
        msg "$pkg já está na versão mais recente ($curver)"
    fi
}

# --------------------------------------------------------------
# Rebuild do sistema inteiro (world)
# --------------------------------------------------------------
world_rebuild() {
    msg "Reconstruindo todo o sistema..."
    for pkg in $(cat "$AURORA_DB/installed"); do
        build_pkg "$pkg"
        install_pkg "$pkg"
    done
}

# --------------------------------------------------------------
# Sincronizar repositório
# --------------------------------------------------------------
sync_repo() {
    if [ -d "$AURORA_REPO/.git" ]; then
        msg "Atualizando repositório existente..."
        git -C "$AURORA_REPO" pull
    else
        msg "Clonando repositório..."
        git clone "$AURORA_REPO_URL" "$AURORA_REPO"
    fi
}

# --------------------------------------------------------------
# Help
# --------------------------------------------------------------
show_help() {
    cat <<EOF
Aurora - Gerenciador de Pacotes

Uso: aurora <comando> [pacotes]

Comandos:
  build <pkg>       - Compilar um pacote
  install <pkg>     - Instalar um pacote
  remove <pkg>      - Remover um pacote
  upgrade <pkg>     - Atualizar um pacote
  world             - Recompilar todo o sistema
  sync              - Sincronizar repositório git
  deps <pkg>        - Mostrar árvore de dependências
  help              - Mostrar esta ajuda
EOF
}

# --------------------------------------------------------------
# Dispatcher
# --------------------------------------------------------------
cmd="$1"; shift || true

case "$cmd" in
    build)     build_pkg "$@" ;;
    install)   for p in "$@"; do install_pkg "$p"; done ;;
    remove)    for p in "$@"; do remove_pkg "$p"; done ;;
    upgrade)   for p in "$@"; do upgrade_pkg "$p"; done ;;
    world)     world_rebuild ;;
    sync)      sync_repo ;;
    deps)      for p in "$@"; do resolve_deps "$p"; done ;;
    help|"")   show_help ;;
    *)         err "Comando desconhecido: $cmd" ;;
esac
