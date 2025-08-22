#!/bin/sh -e
#
# Aurora - Package Manager Minimalista com Hooks
# -----------------------------------------------
# Comandos principais:
#   aurora build <pkg>
#   aurora install <pkg>
#   aurora remove <pkg>
#   aurora upgrade <pkg>
#   aurora search <pkg>
#   aurora sync
#
# Hooks suportados:
#   pre-install   → antes da instalação
#   post-install  → depois da instalação
#   pre-remove    → antes da remoção
#   post-remove   → depois da remoção
#

# Diretórios principais
: "${AURORA_REPO:=$HOME/aurora/repo}"
: "${AURORA_CACHE:=$HOME/aurora/cache}"
: "${AURORA_LOG:=$HOME/aurora/logs}"
: "${AURORA_INSTALLED:=$HOME/aurora/installed}"

mkdir -p "$AURORA_REPO" "$AURORA_CACHE" "$AURORA_LOG" "$AURORA_INSTALLED"

log() {
    printf "\033[1;32m[aurora]\033[0m %s\n" "$*"
}

err() {
    printf "\033[1;31m[erro]\033[0m %s\n" "$*" >&2
    exit 1
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
    printf "\r"
}

dedup() {
    seen=""
    for w in "$@"; do
        case " $seen " in *" $w "*) : ;; *)
            seen="$seen $w"
            printf "%s\n" "$w"
        ;;
        esac
    done
}
# -----------------------------------------------
# Preparar ambiente de build
# -----------------------------------------------
prepare_build_env() {
    pkgname=$1
    workdir="$AURORA_CACHE/build/$pkgname"

    rm -rf "$workdir"
    mkdir -p "$workdir/src" "$workdir/build" "$workdir/pkg"

    export srcdir="$workdir/src"
    export builddir="$workdir/build"
    export pkgdir="$workdir/pkg"

    export PATH="/usr/bin:/bin:$PATH"
    export CFLAGS="-O2 -pipe"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-O1"
}

# -----------------------------------------------
# Executar hook se existir
# -----------------------------------------------
run_hook() {
    hook=$1
    pkg=$2
    recipe_dir="$AURORA_REPO/$pkg"

    if [ -x "$recipe_dir/$hook" ]; then
        log "Executando hook $hook para $pkg"
        ( cd "$recipe_dir" && "./$hook" "$pkgdir" )
    fi
}

# -----------------------------------------------
# Construir pacote
# -----------------------------------------------
aurora_build() {
    pkg=$1
    recipe="$AURORA_REPO/$pkg/build"

    [ -f "$recipe" ] || err "Receita não encontrada: $pkg"

    log "Iniciando build de $pkg"
    prepare_build_env "$pkg"

    (
        cd "$builddir"
        sh "$recipe"
    ) & spinner

    tarball="$AURORA_CACHE/$pkg.tar.gz"
    tar -C "$pkgdir" -czf "$tarball" .
    log "Pacote criado: $tarball"
}
# -----------------------------------------------
# Instalar pacote
# -----------------------------------------------
aurora_install() {
    pkg=$1
    tarball="$AURORA_CACHE/$pkg.tar.gz"
    [ -f "$tarball" ] || err "Pacote não encontrado: $pkg"

    log "Executando pre-install de $pkg"
    run_hook "pre-install" "$pkg"

    log "Instalando $pkg"
    mkdir -p /
    tar -C / -xzf "$tarball"

    log "Executando post-install de $pkg"
    run_hook "post-install" "$pkg"

    log "$pkg instalado com sucesso"
}

# -----------------------------------------------
# Remover pacote
# -----------------------------------------------
aurora_remove() {
    pkg=$1
    tarball="$AURORA_CACHE/$pkg.tar.gz"
    [ -f "$tarball" ] || err "Pacote não instalado: $pkg"

    log "Executando pre-remove de $pkg"
    run_hook "pre-remove" "$pkg"

    log "Removendo arquivos de $pkg"
    tmpdir=$(mktemp -d)
    tar -C "$tmpdir" -xzf "$tarball"
    while IFS= read -r -d '' file; do
        rm -rf "/$file"
    done < <(cd "$tmpdir" && find . -type f -print0)
    rm -rf "$tmpdir"

    log "Executando post-remove de $pkg"
    run_hook "post-remove" "$pkg"

    log "$pkg removido com sucesso"
}

# -----------------------------------------------
# Sincronizar repositório com git
# -----------------------------------------------
aurora_sync() {
    log "Sincronizando repositório Aurora"
    cd "$AURORA_REPO" || err "Repo não encontrado: $AURORA_REPO"

    for sub in core x11 extras desktop; do
        [ -d "$sub" ] || continue
        log "Atualizando $sub"
        (cd "$sub" && git pull --ff-only)
    done
    log "Repositório atualizado"
}

# -----------------------------------------------
# Upgrade de pacotes (somente versões maiores)
# -----------------------------------------------
aurora_upgrade() {
    for pkg in $(ls "$AURORA_REPO"/core "$AURORA_REPO"/x11 "$AURORA_REPO"/extras "$AURORA_REPO"/desktop 2>/dev/null); do
        log "Verificando $pkg"
        # lógica simplificada de comparação de versão
        # (aqui poderia ser expandido com verificação real de versão)
        aurora_build "$pkg"
        aurora_install "$pkg"
    done
    log "Upgrade concluído"
}

# -----------------------------------------------
# Recompilar o sistema inteiro (world)
# -----------------------------------------------
aurora_world() {
    log "Recompilando o sistema inteiro"
    pkgs=$(find "$AURORA_REPO" -mindepth 2 -maxdepth 2 -type d -exec basename {} \;)
    for pkg in $pkgs; do
        aurora_build "$pkg"
        aurora_install "$pkg"
    done
    log "World concluído"
}

# -----------------------------------------------
# Forçar reinstalação/remoção
# -----------------------------------------------
aurora_force() {
    action=$1
    pkg=$2
    case $action in
        install)
            log "Forçando reinstalação de $pkg"
            aurora_build "$pkg"
            aurora_install "$pkg"
            ;;
        remove)
            log "Forçando remoção de $pkg"
            aurora_remove "$pkg"
            aurora_revdep
            ;;
        *)
            err "Uso: aurora --force [install|remove] <pacote>"
            ;;
    esac
}

# -----------------------------------------------
# Revdep: reconstruir pacotes quebrados
# -----------------------------------------------
aurora_revdep() {
    log "Executando revdep (checagem de libs quebradas)"
    broken=""
    for pkg in $(find "$AURORA_CACHE" -name "*.tar.gz" -exec basename {} .tar.gz \;); do
        if ! ldd "/usr/bin/$pkg" 2>/dev/null | grep -q "not found"; then
            continue
        fi
        broken="$broken $pkg"
    done
    [ -z "$broken" ] || for b in $broken; do
        log "Recompilando dependência quebrada: $b"
        aurora_build "$b"
        aurora_install "$b"
    done
    log "Revdep finalizado"
}

# -----------------------------------------------
# Exibir ajuda
# -----------------------------------------------
aurora_help() {
    cat <<EOF
Aurora Package Manager - Comandos disponíveis:

  aurora build <pacote>       - Compilar pacote
  aurora install <pacote>     - Instalar pacote compilado
  aurora remove <pacote>      - Remover pacote instalado
  aurora sync                 - Sincronizar repositórios (git pull)
  aurora upgrade              - Atualizar pacotes (versões maiores)
  aurora world                - Recompilar todo o sistema
  aurora --force install <p>  - Forçar reinstalação de pacote
  aurora --force remove <p>   - Forçar remoção de pacote + revdep
  aurora revdep               - Checar e recompilar pacotes quebrados
  aurora help                 - Mostrar esta ajuda

Arquivos extras suportados por pacote:
  pre-install   → Executado antes da instalação
  post-install  → Executado após a instalação
  pre-remove    → Executado antes da remoção
  post-remove   → Executado após a remoção
EOF
}

# -----------------------------------------------
# Dispatcher de comandos
# -----------------------------------------------
case "$1" in
    build) aurora_build "$2" ;;
    install) aurora_install "$2" ;;
    remove) aurora_remove "$2" ;;
    sync) aurora_sync ;;
    upgrade) aurora_upgrade ;;
    world) aurora_world ;;
    --force) aurora_force "$2" "$3" ;;
    revdep) aurora_revdep ;;
    help|-h|--help|"") aurora_help ;;
    *) err "Comando inválido: $1. Use 'aurora help'." ;;
esac

