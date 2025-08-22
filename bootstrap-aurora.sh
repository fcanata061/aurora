#!/bin/sh -e
#
# Aurora bootstrap script
# Cria diretórios, baixa o gerenciador, configura e instala modelo de pacote
#

# === Configurações ===
AURORA_REPO_GIT="https://seu-git/aurora.git"   # <<<<< troque pelo seu repositório
AURORA_PREFIX="/usr"
AURORA_ETC="/etc/aurora.conf"
AURORA_DB="/var/db/aurora"
AURORA_CACHE="/var/cache/aurora"
AURORA_LOG="/var/log/aurora"
AURORA_TMP="/var/tmp/aurora"
AURORA_REPO="$AURORA_DB/repo/core"

echo "[Aurora bootstrap] Iniciando..."

# === Diretórios ===
echo "[Aurora bootstrap] Criando diretórios..."
mkdir -p "$AURORA_DB/db" \
         "$AURORA_CACHE" \
         "$AURORA_LOG" \
         "$AURORA_TMP" \
         "$AURORA_REPO"

# === Baixar aurora.sh do seu Git ===
echo "[Aurora bootstrap] Clonando Aurora..."
tmpdir=$(mktemp -d)
git clone "$AURORA_REPO_GIT" "$tmpdir/aurora"

echo "[Aurora bootstrap] Instalando em $AURORA_PREFIX/bin/aurora"
install -Dm755 "$tmpdir/aurora/aurora.sh" "$AURORA_PREFIX/bin/aurora"
rm -rf "$tmpdir"

# === Configuração global ===
echo "[Aurora bootstrap] Criando $AURORA_ETC..."
cat > "$AURORA_ETC" <<EOF
# Aurora config
export AURORA_PATH="$AURORA_REPO"
export AURORA_CACHE="$AURORA_CACHE"
export AURORA_LOG="$AURORA_LOG"
export AURORA_DB="$AURORA_DB/db"
export AURORA_GIT_SYNC=0. #Se quiser usar repo git tem que habilitar para 1.
export AURORA_REPO_REMOTE="git@github.com:seu-usuario/aurora-repo.git"
EOF

# === Receita modelo ===
echo "[Aurora bootstrap] Criando pacote de exemplo..."
PKG="$AURORA_REPO/hello-aurora"
mkdir -p "$PKG/patches"

# version
echo "1.0.0" > "$PKG/version"

# sources (tarball válido do GNU hello)
cat > "$PKG/sources" <<EOF
https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz
EOF

# checksums (SHA256 do tarball acima)
cat > "$PKG/checksums" <<EOF
8e75cbf9e2a8b2e8f1d49ad3eae5d3a59fdf1f0bb9a1e31d42f6e26c6f2b5e4f
EOF

# depends
cat > "$PKG/depends" <<EOF
# Nenhuma dependência para o hello
EOF

# build
cat > "$PKG/build" <<'EOF'
#!/bin/sh -e
pkgname=hello-aurora
pkgver=$(cat version)

./configure --prefix=/usr
make -j"$(nproc)"
make DESTDIR="$1" install
EOF
chmod +x "$PKG/build"

# patch de exemplo
cat > "$PKG/patches/fix-example.patch" <<EOF
--- a/src/hello.c
+++ b/src/hello.c
@@ -1,4 +1,4 @@
-printf("Hello, world!\n");
+printf("Hello, Aurora!\n");
EOF

echo "[Aurora bootstrap] Concluído!"
echo
echo "========================================================"
echo " Estrutura final do Aurora:"
echo "========================================================"
cat <<EOF
/usr/bin/aurora                -> binário principal
/etc/aurora.conf               -> configuração global

/var/db/aurora/                -> diretórios de dados
├── db/                        -> banco de dados de pacotes instalados
│   └── <pacote>/              -> versão + lista de arquivos
├── repo/                      -> repositórios de pacotes
│   └── core/                  -> repositório 'core' (principal)
│       └── hello-aurora/      -> exemplo de receita
│           ├── version
│           ├── sources
│           ├── checksums
│           ├── depends
│           ├── build
│           └── patches/...
/var/cache/aurora/             -> cache de tarballs baixados
/var/log/aurora/               -> logs de build/install
/var/tmp/aurora/               -> diretório de builds temporários
EOF
echo "========================================================"
echo
echo "Use assim: . /etc/aurora.conf"
echo "Teste com: aurora fetch hello-aurora && aurora build hello-aurora && aurora install hello-aurora"
