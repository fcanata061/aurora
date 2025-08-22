#!/bin/sh
# Aurora Bootstrap Installer
# Cria toda a estrutura de diretórios e baixa o Aurora + repositório de pacotes

set -e

# =========================
# CONFIGURAÇÃO
# =========================
AURORA_PREFIX="/usr/local/bin"
AURORA_ETC="/etc"
AURORA_VAR="/var/db/aurora"
AURORA_CACHE="/var/cache/aurora"
AURORA_LOG="/var/log/aurora"

# Caminho do repositório git remoto (ajuste para o seu)
AURORA_REPO_REMOTE="git@github.com:seu-usuario/aurora-repo.git"

# =========================
# CRIAÇÃO DE DIRETÓRIOS
# =========================
echo "[+] Criando diretórios principais..."
mkdir -p "$AURORA_PREFIX"
mkdir -p "$AURORA_ETC"
mkdir -p "$AURORA_VAR"
mkdir -p "$AURORA_CACHE"
mkdir -p "$AURORA_LOG"

# Diretórios internos
mkdir -p "$AURORA_VAR/db"
mkdir -p "$AURORA_VAR/repo"

# =========================
# BAIXAR AURORA DO GIT
# =========================
echo "[+] Baixando Aurora package manager..."
if [ ! -d "$AURORA_VAR/aurora" ]; then
    git clone https://github.com/seu-usuario/aurora.git "$AURORA_VAR/aurora"
else
    echo "[=] Aurora já existe em $AURORA_VAR/aurora, atualizando..."
    git -C "$AURORA_VAR/aurora" pull
fi

# Instala aurora.sh no PATH
install -m 755 "$AURORA_VAR/aurora/aurora.sh" "$AURORA_PREFIX/aurora"

# =========================
# CLONAR O REPOSITÓRIO DE PACOTES
# =========================
echo "[+] Clonando repositório de pacotes..."
if [ ! -d "$AURORA_VAR/repo/.git" ]; then
    git clone "$AURORA_REPO_REMOTE" "$AURORA_VAR/repo"
else
    echo "[=] Repositório já existe em $AURORA_VAR/repo, atualizando..."
    git -C "$AURORA_VAR/repo" pull
fi

# =========================
# CRIAR CONFIGURAÇÃO PADRÃO
# =========================
echo "[+] Criando configuração padrão em $AURORA_ETC/aurora.conf..."

cat > "$AURORA_ETC/aurora.conf" <<EOF
# Aurora Package Manager Configuration

# Repositórios (um único repo com subpastas)
export AURORA_PATH="$AURORA_VAR/repo/core:$AURORA_VAR/repo/extra:$AURORA_VAR/repo/x11:$AURORA_VAR/repo/desktop"

# Cache, logs e banco de dados
export AURORA_CACHE="$AURORA_CACHE"
export AURORA_LOG="$AURORA_LOG"
export AURORA_DB="$AURORA_VAR/db"

# Git sync
export AURORA_GIT_SYNC=1
export AURORA_REPO_REMOTE="$AURORA_REPO_REMOTE"
EOF

echo "[✓] Bootstrap concluído!"
echo
echo "Estrutura final esperada:"
echo "
/etc/aurora.conf
/usr/local/bin/aurora
/var/db/aurora/
 ├── aurora/         -> código-fonte do gerenciador
 ├── db/             -> banco de dados de pacotes
 └── repo/           -> repositório Git clonado
      ├── core/
      ├── extra/
      ├── x11/
      └── desktop/
/var/cache/aurora    -> cache de downloads
/var/log/aurora      -> logs
"
