#!/bin/sh
# Aurora - Package Manager (inspirado no KISS Linux)
# POSIX Shell, sem dependências externas além de coreutils, tar, gzip/xz/zstd, etc.

set -eu

# =====================
# Configuração padrão
# =====================
: "${AURORA_PATH:=${XDG_DATA_HOME:-$HOME/.local/share}/aurora/repos}"
: "${AURORA_DB:=${XDG_DATA_HOME:-$HOME/.local/share}/aurora/db}"
: "${AURORA_SRC:=${XDG_CACHE_HOME:-$HOME/.cache}/aurora/sources}"
: "${AURORA_LOG:=${XDG_STATE_HOME:-$HOME/.local/state}/aurora/log}"
: "${AURORA_BUILD:=${TMPDIR:-/tmp}/aurora-build}"
: "${AURORA_WORLD:=${AURORA_DB}/world}"
: "${AURORA_GIT_SYNC:=0}"   # 1=ativar sync automático dos repositórios git

# ferramentas externas (detecta quais usar)
AURORA_TAR=${AURORA_TAR:-tar}
AURORA_SHA256=${AURORA_SHA256:-sha256sum}

# sudo opcional
if command -v doas >/dev/null 2>&1; then
    AURORA_SUDO=${AURORA_SUDO:-doas}
elif command -v sudo >/dev/null 2>&1; then
    AURORA_SUDO=${AURORA_SUDO:-sudo}
else
    AURORA_SUDO=""
fi

# =====================
# Funções utilitárias
# =====================
msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

ensure_dirs() {
    mkdir -p "$AURORA_DB/installed" "$AURORA_SRC" "$AURORA_LOG" "$AURORA_BUILD"
    touch "$AURORA_WORLD"
}

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"; done; }

# logging
log() {
    mkdir -p "$AURORA_LOG"
    printf '[%s] %s\n' "$(ts)" "$*" >>"$AURORA_LOG/aurora.log"
}

# spinner simples
spinner() {
    pid=$1; shift
    i=0; chars='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r[%c] %s" "${chars:$i:1}" "$*" >&2
        sleep 0.2
    done
    printf '\r    \r' >&2
}

# =====================
# DB e pacotes
# =====================
pkg_installed() { [ -d "$AURORA_DB/installed/$1" ]; }
pkg_version_installed() { [ -f "$AURORA_DB/installed/$1/version" ] && cat "$AURORA_DB/installed/$1/version"; }

recipe_path() {
    for base in ${AURORA_PATH//:/ }; do
        [ -d "$base/$1" ] && { printf '%s/%s\n' "$base" "$1"; return 0; }
    done
    return 1
}

pkg_version_repo() { dir=$(recipe_path "$1") || return 1; cat "$dir/version"; }
pkg_depends_repo() { dir=$(recipe_path "$1") || return 1; [ -f "$dir/depends" ] && grep -v '^#' "$dir/depends" || true; }

# =====================
# Resolver dependências
# =====================
resolve_deps() {
    seen=""; order=""
    dfs() {
        pkg="$1"
        case " $seen " in *" $pkg "*) return;; esac
        seen="$seen $pkg"
        for d in $(pkg_depends_repo "$pkg"); do dfs "$d"; done
        order="$order $pkg"
    }
    for p in "$@"; do dfs "$p"; done
    printf '%s\n' $order
}

# =====================
# Fetch/extract/patch
# =====================
fetch_sources() {
    dir=$1; cd "$AURORA_SRC"
    while read -r url; do
        [ -z "$url" ] && continue
        file=$(basename "$url")
        [ -f "$file" ] || curl -L -o "$file" "$url"
    done <"$dir/sources"
}

verify_checksums() {
    dir=$1; cd "$AURORA_SRC"
    [ -f "$dir/checksums" ] || return 0
    sha256sum -c "$dir/checksums"
}

extract_sources() {
    dir=$1; dest=$2; mkdir -p "$dest"; cd "$dest"
    while read -r url; do
        [ -z "$url" ] && continue
        file="$AURORA_SRC/$(basename "$url")"
        case "$file" in
            *.tar.gz|*.tgz) tar -xzf "$file";;
            *.tar.xz) tar -xJf "$file";;
            *.tar.zst) zstd -d <"$file" | tar -xf -;;
            *.zip) unzip "$file";;
            *) cp "$file" .;;
        esac
    done <"$dir/sources"
}

apply_patches() {
    dir=$1; [ -d "$dir/patches" ] || return 0
    for p in "$dir"/patches/*.patch; do [ -f "$p" ] && patch -p1 <"$p"; done
}

# =====================
# Build/Install/Remove
# =====================
build_pkg() {
    pkg=$1; dir=$(recipe_path "$pkg") || die "no recipe $pkg"
    work="$AURORA_BUILD/$pkg"; rm -rf "$work"; mkdir -p "$work"
    fetch_sources "$dir"; verify_checksums "$dir"; extract_sources "$dir" "$work"
    cd "$work"/* || cd "$work"
    apply_patches "$dir"
    export DESTDIR="$AURORA_BUILD/$pkg/pkgdir"
    mkdir -p "$DESTDIR"
    sh "$dir/build"
}

install_pkg() {
    pkg=$1; dir=$(recipe_path "$pkg") || die "no recipe $pkg"
    ver=$(pkg_version_repo "$pkg")
    if pkg_installed "$pkg"; then
        old=$(pkg_version_installed "$pkg")
        [ "$old" = "$ver" ] && { msg "$pkg-$ver já instalado"; return; }
    fi
    for d in $(pkg_depends_repo "$pkg"); do install_pkg "$d"; done
    build_pkg "$pkg"
    ${AURORA_SUDO:-} cp -a "$AURORA_BUILD/$pkg/pkgdir/"* /
    mdir="$AURORA_DB/installed/$pkg"
    ${AURORA_SUDO:-} rm -rf "$mdir"; ${AURORA_SUDO:-} mkdir -p "$mdir"
    printf '%s\n' "$ver" | ${AURORA_SUDO:-} tee "$mdir/version" >/dev/null
    pkg_depends_repo "$pkg" | ${AURORA_SUDO:-} tee "$mdir/depends" >/dev/null
    find "$AURORA_BUILD/$pkg/pkgdir" -type f | sed "s|$AURORA_BUILD/$pkg/pkgdir||" | ${AURORA_SUDO:-} tee "$mdir/manifest" >/dev/null
    msg "instalado $pkg-$ver"
}

remove_pkg() {
    pkg=$1; shift || true
    [ "$1" = "--force" ] && force=1 || force=0
    mdir="$AURORA_DB/installed/$pkg"
    [ -d "$mdir" ] || die "$pkg não instalado"
    if [ $force -eq 0 ]; then
        for p in "$AURORA_DB"/installed/*; do
            [ -d "$p" ] || continue
            grep -qx "$pkg" "$p/depends" 2>/dev/null && die "não pode remover $pkg, usado por $(basename "$p")"
        done
    fi
    while read -r f; do ${AURORA_SUDO:-} rm -f "/$f" || true; done <"$mdir/manifest"
    ${AURORA_SUDO:-} rm -rf "$mdir"
    msg "removido $pkg"
}

# =====================
# Revdep / Orphans / World
# =====================
revdep() {
    for p in "$AURORA_DB"/installed/*; do
        [ -d "$p" ] || continue; pkg=$(basename "$p")
        for d in $(pkg_depends_repo "$pkg" || true); do
            pkg_installed "$d" || { warn "$pkg quebrado (falta $d)"; install_pkg "$pkg"; }
        done
    done
}

prune_orphans() {
    for p in "$AURORA_DB"/installed/*; do
        [ -d "$p" ] || continue; pkg=$(basename "$p")
        grep -qx "$pkg" "$AURORA_WORLD" || {
            used=0
            for q in "$AURORA_DB"/installed/*; do
                [ -d "$q" ] || continue
                grep -qx "$pkg" "$q/depends" 2>/dev/null && { used=1; break; }
            done
            [ $used -eq 0 ] && remove_pkg "$pkg"
        }
    done
}

world_rebuild() {
    pkgs=$(cat "$AURORA_WORLD")
    for p in $(resolve_deps $pkgs); do install_pkg "$p"; done
}

# =====================
# Comandos principais
# =====================
cmd_path(){ printf '%s\n' "$AURORA_PATH"; }
cmd_search(){ pat=$1; for base in ${AURORA_PATH//:/ }; do find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep "$pat" || true; done; }
cmd_show(){ recipe_path "$1" || die "não encontrado"; }
cmd_ver(){ pkg=$1; if [ "$2" = "--installed" ]; then pkg_version_installed "$pkg" || die "não instalado"; else pkg_version_repo "$pkg" || die "não existe no repo"; fi; }
cmd_list(){ for p in "$AURORA_DB"/installed/*; do [ -d "$p" ] && basename "$p"; done; }
cmd_files(){ pkg=$1; cat "$AURORA_DB/installed/$pkg/manifest"; }
cmd_owns(){ path=$1; for p in "$AURORA_DB"/installed/*; do grep -qx "$path" "$p/manifest" 2>/dev/null && basename "$p"; done; }

# =====================
# Ajuda
# =====================
usage(){ cat << EOF
Aurora (POSIX) — comandos:
  path, search <pat>, show <pkg>, ver [--installed] <pkg>
  fetch <pkg...>, build <pkg...>, install <pkg...>, remove <pkg...>, upgrade <pkg...>
  list, files <pkg>, owns <path>
  orphans, world-add <pkg...>, world-rm <pkg...>, world-rebuild
  revdep
EOF
}

# =====================
# Main
# =====================
main(){
    ensure_dirs
    need awk sed grep sort patch tee mktemp printf cut xargs "$AURORA_TAR" "$AURORA_SHA256"
    cmd="${1:-help}"; shift || true
    case "$cmd" in
        path) cmd_path;;
        search) cmd_search "${1:-}";;
        show) cmd_show "${1:-}";;
        ver) cmd_ver "${1:-}" "${2:-}";;
        fetch) cmd_fetch "$@";;
        build) cmd_build "$@";;
        install) cmd_install "$@";;
        remove) cmd_remove "$@";;
        upgrade) cmd_upgrade "$@";;
        list) cmd_list;;
        files) cmd_files "$@";;
        owns) cmd_owns "$@";;
        orphans) cmd_orphans;;
        world-add) cmd_world_add "$@";;
        world-rm) cmd_world_rm "$@";;
        world-rebuild) cmd_world_rebuild;;
        revdep) revdep;;
        help|*) usage;;
    esac
}

main "$@"

# =====================
# Build/Install/Remove
# =====================
build_pkg() {
    pkg=$1; dir=$(recipe_path "$pkg") || die "no recipe $pkg"
    work="$AURORA_BUILD/$pkg"; rm -rf "$work"; mkdir -p "$work"
    fetch_sources "$dir"; verify_checksums "$dir"; extract_sources "$dir" "$work"
    cd "$work"/* || cd "$work"
    apply_patches "$dir"
    export DESTDIR="$AURORA_BUILD/$pkg/pkgdir"
    mkdir -p "$DESTDIR"
    sh "$dir/build"
}

install_pkg() {
    pkg=$1; dir=$(recipe_path "$pkg") || die "no recipe $pkg"
    ver=$(pkg_version_repo "$pkg")
    if pkg_installed "$pkg"; then
        old=$(pkg_version_installed "$pkg")
        [ "$old" = "$ver" ] && { msg "$pkg-$ver já instalado"; return; }
    fi
    for d in $(pkg_depends_repo "$pkg"); do install_pkg "$d"; done
    build_pkg "$pkg"
    ${AURORA_SUDO:-} cp -a "$AURORA_BUILD/$pkg/pkgdir/"* /
    mdir="$AURORA_DB/installed/$pkg"
    ${AURORA_SUDO:-} rm -rf "$mdir"; ${AURORA_SUDO:-} mkdir -p "$mdir"
    printf '%s\n' "$ver" | ${AURORA_SUDO:-} tee "$mdir/version" >/dev/null
    pkg_depends_repo "$pkg" | ${AURORA_SUDO:-} tee "$mdir/depends" >/dev/null
    find "$AURORA_BUILD/$pkg/pkgdir" -type f | sed "s|$AURORA_BUILD/$pkg/pkgdir||" | ${AURORA_SUDO:-} tee "$mdir/manifest" >/dev/null
    msg "instalado $pkg-$ver"
}

remove_pkg() {
    pkg=$1; shift || true
    [ "$1" = "--force" ] && force=1 || force=0
    mdir="$AURORA_DB/installed/$pkg"
    [ -d "$mdir" ] || die "$pkg não instalado"
    if [ $force -eq 0 ]; then
        for p in "$AURORA_DB"/installed/*; do
            [ -d "$p" ] || continue
            grep -qx "$pkg" "$p/depends" 2>/dev/null && die "não pode remover $pkg, usado por $(basename "$p")"
        done
    fi
    while read -r f; do ${AURORA_SUDO:-} rm -f "/$f" || true; done <"$mdir/manifest"
    ${AURORA_SUDO:-} rm -rf "$mdir"
    msg "removido $pkg"
}

# =====================
# Revdep / Orphans / World
# =====================
revdep() {
    for p in "$AURORA_DB"/installed/*; do
        [ -d "$p" ] || continue; pkg=$(basename "$p")
        for d in $(pkg_depends_repo "$pkg" || true); do
            pkg_installed "$d" || { warn "$pkg quebrado (falta $d)"; install_pkg "$pkg"; }
        done
    done
}

prune_orphans() {
    for p in "$AURORA_DB"/installed/*; do
        [ -d "$p" ] || continue; pkg=$(basename "$p")
        grep -qx "$pkg" "$AURORA_WORLD" || {
            used=0
            for q in "$AURORA_DB"/installed/*; do
                [ -d "$q" ] || continue
                grep -qx "$pkg" "$q/depends" 2>/dev/null && { used=1; break; }
            done
            [ $used -eq 0 ] && remove_pkg "$pkg"
        }
    done
}

world_rebuild() {
    pkgs=$(cat "$AURORA_WORLD")
    for p in $(resolve_deps $pkgs); do install_pkg "$p"; done
}

# =====================
# Comandos principais
# =====================
cmd_path(){ printf '%s\n' "$AURORA_PATH"; }
cmd_search(){ pat=$1; for base in ${AURORA_PATH//:/ }; do find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep "$pat" || true; done; }
cmd_show(){ recipe_path "$1" || die "não encontrado"; }
cmd_ver(){ pkg=$1; if [ "$2" = "--installed" ]; then pkg_version_installed "$pkg" || die "não instalado"; else pkg_version_repo "$pkg" || die "não existe no repo"; fi; }
cmd_list(){ for p in "$AURORA_DB"/installed/*; do [ -d "$p" ] && basename "$p"; done; }
cmd_files(){ pkg=$1; cat "$AURORA_DB/installed/$pkg/manifest"; }
cmd_owns(){ path=$1; for p in "$AURORA_DB"/installed/*; do grep -qx "$path" "$p/manifest" 2>/dev/null && basename "$p"; done; }

# =====================
# Ajuda
# =====================
usage(){ cat << EOF
Aurora (POSIX) — comandos:
  path, search <pat>, show <pkg>, ver [--installed] <pkg>
  fetch <pkg...>, build <pkg...>, install <pkg...>, remove <pkg...>, upgrade <pkg...>
  list, files <pkg>, owns <path>
  orphans, world-add <pkg...>, world-rm <pkg...>, world-rebuild
  revdep
EOF
}

# =====================
# Main
# =====================
main(){
    ensure_dirs
    need awk sed grep sort patch tee mktemp printf cut xargs "$AURORA_TAR" "$AURORA_SHA256"
    cmd="${1:-help}"; shift || true
    case "$cmd" in
        path) cmd_path;;
        search) cmd_search "${1:-}";;
        show) cmd_show "${1:-}";;
        ver) cmd_ver "${1:-}" "${2:-}";;
        fetch) cmd_fetch "$@";;
        build) cmd_build "$@";;
        install) cmd_install "$@";;
        remove) cmd_remove "$@";;
        upgrade) cmd_upgrade "$@";;
        list) cmd_list;;
        files) cmd_files "$@";;
        owns) cmd_owns "$@";;
        orphans) cmd_orphans;;
        world-add) cmd_world_add "$@";;
        world-rm) cmd_world_rm "$@";;
        world-rebuild) cmd_world_rebuild;;
        revdep) revdep;;
        help|*) usage;;
    esac
}

main "$@"
