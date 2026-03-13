#!/usr/bin/env bash
set -euo pipefail

### KONFIGURATION

NAS_SHARE="//192.168.1.112/NetBackup"
NAS_MOUNT="/mnt/nas_backup"
NAS_USER="proxmox_smb"
NAS_PASS="dh8fw28h8790..dw"

COMPOSE_DIR="/srv/ai-office"
CONTAINER="paperless"
EXPORT_BASE="/srv/ai-office/export"

DATE=$(date +%Y-%m-%d_%H-%M-%S)

RETENTION_LOCAL_DAYS=7
RETENTION_NAS_DAYS=30

# === SCHALTER: Lokale Kopie behalten? ===
# false = Nur NAS (spart Platz, aktuell empfohlen)
# true  = Zusätzlich lokale Kopie (wenn größere Platte)
LOCAL_COPY=false

# Mindestens freier Speicher erforderlich
MIN_FREE_GB_NO_LOCAL=5   # Wenn LOCAL_COPY=false
MIN_FREE_GB_WITH_LOCAL=20 # Wenn LOCAL_COPY=true

### FUNKTIONEN

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    log "FEHLER: $*" >&2
    # Cleanup bei Fehler
    [ -f "$TMP_EXPORT_LIST" ] && rm -f "$TMP_EXPORT_LIST" 2>/dev/null || true
    exit 1
}

check_disk_space() {
    local path=$1
    local min_gb=$2
    
    # Freier Speicher in GB
    local free_gb=$(df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    log "Verfügbarer Speicher auf $path: ${free_gb}GB (Minimum: ${min_gb}GB)"
    
    if [ "$free_gb" -lt "$min_gb" ]; then
        error_exit "Nicht genug Speicherplatz! Benötigt: ${min_gb}GB, Verfügbar: ${free_gb}GB"
    fi
}

cleanup_old_exports() {
    log "Räume alte Export-Verzeichnisse auf..."
    find "$EXPORT_BASE" -mindepth 1 -maxdepth 1 ! -name '*.tar.gz' -exec rm -rf {} + 2>/dev/null || true
}

mount_nas() {
    if ! mountpoint -q "$NAS_MOUNT"; then
        log "Mounte NAS..."
        mount -t cifs "$NAS_SHARE" "$NAS_MOUNT" -o username=$NAS_USER,password=$NAS_PASS,vers=3.0,iocharset=utf8,file_mode=0660,dir_mode=0770 || error_exit "NAS-Mount fehlgeschlagen"
        log "NAS erfolgreich gemountet"
    else
        log "NAS bereits gemountet"
    fi
    
    # Prüfe ob NAS wirklich schreibbar ist
    if ! touch "$NAS_MOUNT/.test_write" 2>/dev/null; then
        error_exit "NAS ist nicht schreibbar!"
    fi
    rm -f "$NAS_MOUNT/.test_write"
}

### HAUPTPROGRAMM

log "=== Paperless Backup gestartet ==="
log "Modus: LOCAL_COPY=$LOCAL_COPY"

# Verzeichnisse erstellen
mkdir -p "$EXPORT_BASE"
mkdir -p "$NAS_MOUNT"

# Disk-Space prüfen abhängig vom Modus
if [ "$LOCAL_COPY" = true ]; then
    check_disk_space "/" "$MIN_FREE_GB_WITH_LOCAL"
else
    check_disk_space "/" "$MIN_FREE_GB_NO_LOCAL"
fi

# NAS mounten und Schreibbarkeit prüfen
mount_nas

cd "$COMPOSE_DIR"

# Alte Export-Verzeichnisse aufräumen
cleanup_old_exports

# Paperless Export durchführen
log "Starte Paperless Document Export..."
docker compose exec -T --user paperless "$CONTAINER" document_exporter /usr/src/paperless/export || error_exit "Document Export fehlgeschlagen"
log "Document Export abgeschlossen"

# Temporäre Liste der exportierten Dateien für Größenberechnung
TMP_EXPORT_LIST=$(mktemp)
find "$EXPORT_BASE" -mindepth 1 ! -name '*.tar.gz' > "$TMP_EXPORT_LIST"
EXPORT_SIZE=$(du -sh "$EXPORT_BASE" | cut -f1)
log "Export-Größe: $EXPORT_SIZE"

# === BACKUP ERSTELLEN ===

if [ "$LOCAL_COPY" = true ]; then
    # Modus 1: Lokale Kopie + NAS
    log "Erstelle lokales Backup..."
    LOCAL_ARCHIVE="$EXPORT_BASE/paperless_export_$DATE.tar.gz"
    tar -czf "$LOCAL_ARCHIVE" -C "$EXPORT_BASE" . || error_exit "Archiv-Erstellung fehlgeschlagen"
    
    ARCHIVE_SIZE=$(du -h "$LOCAL_ARCHIVE" | cut -f1)
    log "Lokales Archiv erstellt: $ARCHIVE_SIZE"
    
    log "Kopiere auf NAS..."
    rsync -av --progress "$LOCAL_ARCHIVE" "$NAS_MOUNT/" || error_exit "NAS-Sync fehlgeschlagen"
    log "Backup erfolgreich aufs NAS kopiert"
    
    # Alte lokale Backups löschen
    log "Räume alte lokale Backups auf..."
    DELETED_LOCAL=$(find "$EXPORT_BASE" -maxdepth 1 -type f -name 'paperless_export_*.tar.gz' -mtime +$RETENTION_LOCAL_DAYS -delete -print | wc -l)
    log "Lokale Backups gelöscht: $DELETED_LOCAL"
    
else
    # Modus 2: Direkt aufs NAS (kein lokales Backup)
    log "Erstelle Backup direkt auf NAS (kein lokales Backup)..."
    NAS_ARCHIVE="$NAS_MOUNT/paperless_export_$DATE.tar.gz"
    tar -czf "$NAS_ARCHIVE" -C "$EXPORT_BASE" . || error_exit "NAS-Backup fehlgeschlagen"
    
    ARCHIVE_SIZE=$(du -h "$NAS_ARCHIVE" | cut -f1)
    log "NAS-Backup erstellt: $ARCHIVE_SIZE"
fi

# Export-Verzeichnis aufräumen (nur die entpackten Dateien)
log "Räume Export-Verzeichnis auf..."
while IFS= read -r file; do
    [ -e "$file" ] && rm -rf "$file"
done < "$TMP_EXPORT_LIST"
rm -f "$TMP_EXPORT_LIST"

# Alte NAS-Backups löschen (Retention)
log "Wende NAS Retention-Policy an (${RETENTION_NAS_DAYS} Tage)..."
DELETED_NAS=$(find "$NAS_MOUNT" -maxdepth 1 -type f -name 'paperless_export_*.tar.gz' -mtime +$RETENTION_NAS_DAYS -delete -print | wc -l)
log "NAS Backups gelöscht: $DELETED_NAS"

# Finale Statistiken
FREE_SPACE=$(df -h / | awk 'NR==2 {print $4}')
NAS_BACKUPS=$(find "$NAS_MOUNT" -maxdepth 1 -type f -name 'paperless_export_*.tar.gz' | wc -l)

log "=== Backup erfolgreich abgeschlossen ==="
if [ "$LOCAL_COPY" = true ]; then
    log "Archiv lokal: $LOCAL_ARCHIVE ($ARCHIVE_SIZE)"
    log "Archiv NAS: $NAS_MOUNT/paperless_export_$DATE.tar.gz"
else
    log "Archiv NAS: $NAS_ARCHIVE ($ARCHIVE_SIZE)"
fi
log "Verbleibender Speicher: $FREE_SPACE"
log "Backups auf NAS: $NAS_BACKUPS"

