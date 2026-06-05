#!/bin/bash
#
# clean-state.sh
# Part of the macos-clean-state project.
#
# Simple, guided manager for macOS clean device states using native APFS snapshots
# and portable compressed DMG images.
#
# Use for repeatable test resets: capture a "clean start", run tests that pollute
# the device, then quickly revert via Recovery or restore from a DMG on external storage.
#
# Usage:
#   ./clean-state.sh                  # Interactive guided menu (recommended)
#   ./clean-state.sh --help
#   ./clean-state.sh --status
#   ./clean-state.sh --create-snapshot --description "Clean baseline before running Foo v3 tests"
#   ./clean-state.sh --create-dmg --dest /Volumes/MyExternal [--name Clean-2026-06-05.dmg]
#   ./clean-state.sh --tag-snapshot --description "My alias here"
#   ./clean-state.sh --mount-latest
#   ./clean-state.sh --guidance
#
# Inside the interactive menu (the default when you run with no arguments)
# type the letter "h" at any time for a detailed explanation of every option
# and what the destination numbers / d / o mean.
#
# The script is intentionally simple and self-contained (pure bash + Apple tools).
# It will use sudo when needed (you will be prompted for your password).

set -euo pipefail

# ----------------------------- Colors & UI -----------------------------------
if [[ -t 1 ]]; then
    GREEN=$(tput setaf 2 2>/dev/null || echo '')
    RED=$(tput setaf 1 2>/dev/null || echo '')
    YELLOW=$(tput setaf 3 2>/dev/null || echo '')
    BLUE=$(tput setaf 4 2>/dev/null || echo '')
    BOLD=$(tput bold 2>/dev/null || echo '')
    RESET=$(tput sgr0 2>/dev/null || echo '')
else
    GREEN=""; RED=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }

# ----------------------------- Configuration ---------------------------------
DATA_MOUNT="/System/Volumes/Data"
MOUNT_PREFIX="/Volumes/CleanSnapshot"
DEFAULT_DMG_NAME_PREFIX="CleanState"

# Registry for user-provided aliases/descriptions (persists independently of snapshot names)
REGISTRY_FILE="$HOME/Library/Application Support/clean-state/snapshots.log"
REGISTRY_HEADER="# clean-state snapshot registry - timestamp|snapshot_name|alias/description|associated_dmg_path|notes"

# ----------------------------- Helpers ---------------------------------------
require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "This script is for macOS only."
        exit 1
    fi
}

sudo_refresh() {
    # Refresh sudo ticket so later sudo commands don't surprise the user
    if ! sudo -n true 2>/dev/null; then
        info "This action requires admin privileges (sudo). Enter your password if prompted."
        sudo -v
    fi
}

get_data_device() {
    diskutil info "$DATA_MOUNT" 2>/dev/null | awk -F': *' '/Device Node/ {print $2; exit}'
}

get_container() {
    local dev
    dev=$(get_data_device)
    [[ -z "$dev" ]] && return 1
    diskutil info "$dev" 2>/dev/null | awk -F': *' '/APFS Container/ {print $2; exit}'
}

get_latest_snapshot() {
    tmutil listlocalsnapshots "$DATA_MOUNT" 2>/dev/null \
        | grep -v '^Snapshots for disk' \
        | tail -1 | tr -d ' \t'
}

list_all_snapshots() {
    tmutil listlocalsnapshots "$DATA_MOUNT" 2>/dev/null \
        | grep -v '^Snapshots for disk' \
        | sed 's/^[[:space:]]*//' \
        | grep -v '^$' || true
}

print_state() {
    cleanup_stale_clean_dirs
    echo
    echo "${BOLD}=== Current Device State ===${RESET}"
    echo "Data volume : $DATA_MOUNT"
    local dev cont
    dev=$(get_data_device || echo "unknown")
    cont=$(get_container || echo "unknown")
    echo "Device node : $dev"
    echo "Container   : $cont"

    echo
    echo "${BOLD}Local snapshots on Data volume (aliases shown if tagged):${RESET}"
    local snaps
    snaps=$(list_all_snapshots || true)
    if [[ -z "$snaps" ]]; then
        echo "  (none)"
    else
        while IFS= read -r s; do
            local alias
            alias=$(lookup_alias "$s")
            if [[ -n "$alias" ]]; then
                printf "  %s\n      Alias: %s\n" "$s" "$alias"
            else
                echo "  $s"
            fi
        done <<< "$snaps"
    fi

    echo
    echo "${BOLD}Space:${RESET}"
    df -h "$DATA_MOUNT" 2>/dev/null | tail -1 | awk '{printf "  %s used of %s (%s full)\n", $3, $2, $5}'

    echo
    echo "${BOLD}Volumes under /Volumes (potential external targets):${RESET}"
    local found=0
    for p in /Volumes/*; do
        [[ -d "$p" ]] || continue
        local vol
        vol=$(basename "$p")
        case "$vol" in
            Macintosh*|Preboot|Recovery|VM|com.apple*|BACKUP*|CleanSnapshot*) continue ;;
        esac
        # Only show actually mounted volumes (skip leftover dirs)
        if ! mount | grep -q " on $p "; then
            continue
        fi
        local size
        size=$(df -h "$p" 2>/dev/null | tail -1 | awk '{print $2}' || echo "?")
        local writable_mark=""
        if [[ ! -w "$p" ]]; then
            writable_mark=" (may be read-only)"
        fi
        echo "  $p  ($size)$writable_mark"
        found=1
    done

    if [[ $found -eq 0 ]]; then
        echo "  (no obvious external volumes found — connect a drive and re-run)"
    fi
    echo
}

get_external_choice() {
    # Returns a chosen /Volumes/ path or empty
    cleanup_stale_clean_dirs
    local candidates=()
    for p in /Volumes/*; do
        [[ -d "$p" ]] || continue
        local vol
        vol=$(basename "$p")
        case "$vol" in
            Macintosh*|Preboot|Recovery|VM|com.apple*|BACKUP*|CleanSnapshot*) continue ;;
        esac
        # Only real mounted volumes, not leftover directories from failed mounts
        if ! mount | grep -q " on $p "; then
            continue
        fi
        candidates+=("$vol")
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No candidate external volumes detected."
        read -r -p "Enter full destination directory path (e.g. /Volumes/MySSD or ~/Desktop): " dest
        echo "$dest"
        return
    fi

    echo
    echo "Destination options (where the compressed .dmg will be written):"
    echo "  Numbers = real mounted volumes under /Volumes (read-only ones are marked)."
    echo "  d       = your Desktop (always safe)."
    echo "  o       = type any custom path (recommended for a specific folder on your external)."
    echo
    echo "Available destinations:"
    local i=1
    for c in "${candidates[@]}"; do
        local sz
        sz=$(df -h "/Volumes/$c" 2>/dev/null | tail -1 | awk '{print $2}' || echo "?")
        local writable_mark=""
        if [[ ! -w "/Volumes/$c" ]]; then
            writable_mark=" (may be read-only)"
        fi
        printf "  %d) /Volumes/%s  (%s)%s\n" "$i" "$c" "$sz" "$writable_mark"
        ((i++))
    done
    echo "  d) Desktop (~)"
    echo "  o) Other path (type it)"

    local choice
    read -r -p "Choose destination [1-${#candidates[@]} / d / o] (type h for help): " choice

    if [[ "$choice" == "h" || "$choice" == "H" ]]; then
        show_help
        # Re-show the destinations after help
        echo
        echo "Available destinations (after help):"
        local i=1
        for c in "${candidates[@]}"; do
            local sz
            sz=$(df -h "/Volumes/$c" 2>/dev/null | tail -1 | awk '{print $2}' || echo "?")
            local writable_mark=""
            if [[ ! -w "/Volumes/$c" ]]; then
                writable_mark=" (may be read-only)"
            fi
            printf "  %d) /Volumes/%s  (%s)%s\n" "$i" "$c" "$sz" "$writable_mark"
            ((i++))
        done
        echo "  d) Desktop (~)"
        echo "  o) Other path (type it)"
        read -r -p "Choose destination [1-${#candidates[@]} / d / o]: " choice
    fi

    if [[ "$choice" == "d" || "$choice" == "D" ]]; then
        echo "$HOME/Desktop"
    elif [[ "$choice" == "o" || "$choice" == "O" ]]; then
        read -r -p "Enter full path: " p
        echo "$p"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
        echo "/Volumes/${candidates[$((choice-1))]}"
    else
        echo "/Volumes/${candidates[0]}"
    fi
}

cleanup_stale_clean_dirs() {
    # Remove leftover mount point directories from previous failed mount attempts.
    # These pollute the "potential external targets" list (df reports the parent Data volume size)
    # and make the choice menu confusing.
    for base in CleanSnapshot CleanSnapshot-dmg; do
        for d in /Volumes/${base}-*; do
            [[ -d "$d" ]] || continue
            if mount | grep -q " on $d "; then
                continue  # still mounted, leave it alone
            fi
            # Try to remove if empty (non-empty means something went weird)
            rmdir "$d" 2>/dev/null || sudo rmdir "$d" 2>/dev/null || true
        done
    done
}

show_help() {
    cat << 'HELP'

Main menu options explained:

1) Create a new snapshot (mark current state as clean)
   Takes a point-in-time APFS snapshot of your Data volume using `tmutil localsnapshot`.
   This captures the exact "clean" state of the machine (files, apps, settings, etc.).
   Snapshots are very fast and space-efficient (only changed blocks use extra space later).
   The snapshot name will be something like com.apple.TimeMachine.2026-06-05-093009.local.
   You can (and should) immediately give it a human-friendly alias with option 7.

2) List snapshots
   Shows every local APFS snapshot that still exists on the Data volume,
   together with any alias/description you have given it via the registry.

3) Mount a snapshot read-only (inspect the clean state)
   Mounts the chosen snapshot as a read-only volume (usually under /Volumes/CleanSnapshot-...).
   You can then browse it with Finder or `ls` to see exactly what the machine looked like
   at the moment the snapshot was taken, without affecting your live system.
   Use option 5 to unmount it again when you are done.

4) Create compressed DMG from a snapshot (to external or Desktop)
   The main "export" option.
   - Mounts the selected snapshot (read-only).
   - Creates a compressed UDZO .dmg file from it (or from a subfolder such as your Home directory).
   - Writes a companion .info sidecar containing the snapshot name + your alias.
   This .dmg is a portable, restorable image of that clean state.
   You can later restore it in Recovery (Disk Utility → Restore or `asr` command).
   The destination chooser (see below) lets you pick where to save the .dmg.

5) Unmount a snapshot mount
   Cleans up any /Volumes/CleanSnapshot-... volumes you created with option 3.
   Also tries to clean up any leftover empty directories from previous failed attempts.

6) Delete a snapshot
   Permanently removes one or more old snapshots.
   This frees the space they were using on your internal drive.
   Only delete snapshots you no longer need for restores.

7) Tag / give alias to an existing snapshot (persists in registry + sidecar)
   Attaches a memorable description such as "clean install with grok/kimi setup".
   The alias is stored in ~/Library/Application Support/clean-state/snapshots.log
   and is also written into the .info file next to any DMG you create from that snapshot.
   You can optionally also rename the snapshot's internal name (via Disk Utility GUI).
   Renaming may affect whether it appears in Recovery's "Restore from Time Machine" list.

8) Show full restore guidance (Recovery steps)
   Prints step-by-step instructions for restoring the machine to a clean state:
   - Fastest method: boot to Recovery and use "Restore from Time Machine Backup"
     (your local snapshots appear there because they use the com.apple.TimeMachine naming).
   - From a .dmg: use Disk Utility Restore tab or the `asr restore` command in Recovery.
   Always double-check disk identifiers with `diskutil list` before restoring!

9) Refresh / show state again
   Re-scans the machine and reprints the "Current Device State" block.
   Useful after you plug in or remove external drives, or after creating/deleting snapshots.

q) Quit
   Exit the script cleanly.

Destination choices (the "Choose destination [1-N / d / o]:" prompt when using option 4)
---------------------------------------------------------------------------------------
The script looks for real mounted volumes under /Volumes (excluding internal system
volumes and its own temporary CleanSnapshot mount points).

Numbers (1, 2, ...):
  Real external or secondary volumes that were detected as mounted.
  If a volume appears to be mounted read-only (common for the "system" side of an
  external APFS clone), it will be marked "(may be read-only)".
  You normally want the "- Data" volume of an external drive for writing.

d) Desktop (~)
  Always writes the .dmg to your Desktop folder. 100% safe and writable.
  Good for a quick test, then you can manually copy the .dmg + .info file to your
  external drive later.

o) Other path (type it)
  Lets you enter any directory you like.
  Use this when:
  - You want to put the DMG inside a specific subfolder on the external
    (example: /Volumes/Sandisk\ -\ Data/Backups)
  - The auto-detected volumes are all read-only or not what you want.
  - You want to write to a network share, a different internal volume, etc.

After you pick a destination the script will ask:
- Which snapshot (or subfolder of a snapshot) to image.
- It will then mount the snapshot internally, create the compressed DMG,
  write the sidecar .info file, and clean up the temporary mount.

HELP
}

ensure_registry() {
    local dir
    dir=$(dirname "$REGISTRY_FILE")
    mkdir -p "$dir" 2>/dev/null || true
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo "$REGISTRY_HEADER" > "$REGISTRY_FILE"
    fi
}

record_alias() {
    local snap_name="$1"
    local alias="$2"
    local dmg_path="${3:-}"
    local notes="${4:-}"
    [[ -z "$snap_name" || -z "$alias" ]] && return 0
    ensure_registry
    local ts
    ts=$(date +%Y-%m-%d_%H:%M:%S)
    # Avoid duplicate entries for same snap by removing previous
    grep -v "|${snap_name}|" "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" 2>/dev/null || true
    mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE" 2>/dev/null || true
    echo "${ts}|${snap_name}|${alias}|${dmg_path}|${notes}" >> "$REGISTRY_FILE"
    success "Saved alias for snapshot: $alias"
}

lookup_alias() {
    local snap_name="$1"
    [[ -z "$snap_name" || ! -f "$REGISTRY_FILE" ]] && return 0
    grep -F "|${snap_name}|" "$REGISTRY_FILE" 2>/dev/null | tail -1 | cut -d'|' -f3 || true
}

list_snapshots_with_aliases() {
    echo "${BOLD}Local snapshots (with any aliases):${RESET}"
    local snaps
    snaps=$(list_all_snapshots || true)
    if [[ -z "$snaps" ]]; then
        echo "  (none)"
        return
    fi
    while IFS= read -r s; do
        local alias
        alias=$(lookup_alias "$s")
        if [[ -n "$alias" ]]; then
            printf "  %s\n      Alias: %s\n" "$s" "$alias"
        else
            echo "  $s"
        fi
    done <<< "$snaps"
}

# ----------------------------- Actions ---------------------------------------
do_create_snapshot() {
    local desc=${1:-}
    local no_tip=${2:-}   # pass "1" to suppress the "tip" message (used in interactive)
    local marker="/Users/Shared/Clean-State-Info.txt"

    if [[ -n "$desc" ]]; then
        info "Writing self-documenting marker file that will be captured inside this clean snapshot..."
        sudo mkdir -p "$(dirname "$marker")" 2>/dev/null || true
        cat > "$marker" << EOF
This is a clean device state capture created with clean-state.sh

Purpose / Description:
  $desc

Captured at: $(date)
Machine: $(scutil --get LocalHostName 2>/dev/null || hostname)
Data volume device: $(get_data_device 2>/dev/null || echo unknown)

The snapshot created immediately after this file will represent this exact state.
When you mount or restore this snapshot/DMG, this file will be present at $marker
as a reminder of why this clean baseline was made.

You can safely delete this file from the live system after the snapshot if you don't
want it lingering (the version inside the snapshot will remain).
EOF
        success "Marker written to $marker (will be part of the clean snapshot)"
    fi

    info "Creating local APFS snapshot of $DATA_MOUNT ..."
    local output
    output=$(tmutil localsnapshot 2>&1)
    echo "$output"

    local new_snap
    new_snap=$(get_latest_snapshot)
    if [[ -n "$new_snap" ]]; then
        success "New snapshot: $new_snap"
        if [[ -n "$desc" ]]; then
            record_alias "$new_snap" "$desc"
            info "Alias/description saved to registry + embedded in snapshot marker + will appear in future DMG sidecars."
            info "Inside any mount/restore of this snapshot you can read: $marker"
        elif [[ "$no_tip" != "1" ]]; then
            info "Tip: You can tag this snapshot with an alias later using the interactive menu or --tag."
        fi
    fi

    # Optional: remove the live marker so it doesn't stay on the "current" live system
    # (the snapshot already captured it). Comment out the next lines if you want the marker
    # to remain visible on the live system after capture.
    if [[ -n "$desc" && -f "$marker" ]]; then
        rm -f "$marker" 2>/dev/null || sudo rm -f "$marker" 2>/dev/null || true
        info "(Live marker cleaned up; the version inside the snapshot remains.)"
    fi

    echo
    print_state
}

do_tag_snapshot() {
    local snap=${1:-}
    local alias=${2:-}
    if [[ -z "$snap" ]]; then
        echo "Current snapshots:"
        list_snapshots_with_aliases
        read -r -p "Enter snapshot name (or 'latest'): " snap
        if [[ "$snap" == "latest" ]]; then
            snap=$(get_latest_snapshot)
        fi
    fi
    if [[ -z "$snap" ]]; then
        error "No snapshot specified."
        return 1
    fi
    if [[ -z "$alias" ]]; then
        read -r -p "Enter alias / description for '$snap': " alias
    fi
    if [[ -z "$alias" ]]; then
        warn "No alias provided."
        return 0
    fi
    record_alias "$snap" "$alias"
    # Also offer to rename the actual snapshot name (GUI preferred)
    read -r -p "Also rename the snapshot itself in the filesystem? (advanced, may affect Time Machine restore visibility) [y/N]: " do_rename
    if [[ "$do_rename" == "y" || "$do_rename" == "Y" ]]; then
        local dev
        dev=$(get_data_device)
        local new_name="com.apple.TimeMachine.${snap#com.apple.TimeMachine.}-${alias// /_}"
        # Try to make it still look TM-ish
        warn "Renaming snapshots via CLI is limited. Attempting..."
        if diskutil apfs renameSnapshot "$dev" "$snap" "$new_name" 2>&1; then
            success "Renamed snapshot to $new_name"
            # Update registry with new name? For simplicity, record both or let user re-tag
        else
            warn "CLI rename not available or failed."
            info "Please open Disk Utility > View > Show APFS Snapshots, select the volume, find the snapshot, and rename it there."
            info "The new name you choose will become the persistent identifier/alias."
            open -a "Disk Utility" 2>/dev/null || true
        fi
    fi
}

do_list_snapshots() {
    list_snapshots_with_aliases
}

do_mount_snapshot() {
    local snap=${1:-}
    if [[ -z "$snap" ]]; then
        snap=$(get_latest_snapshot)
    fi
    if [[ -z "$snap" ]]; then
        error "No snapshot found. Create one first."
        return 1
    fi

    local data_dev=$(get_data_device)
    if [[ -z "$data_dev" ]]; then
        error "Could not determine the Data volume device node (e.g. /dev/disk3s5)."
        return 1
    fi

    local mnt="${MOUNT_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    info "Mounting snapshot '$snap' read-only at $mnt ..."
    info "Using source device: $data_dev (more reliable than path for root Data volume)"
    sudo_refresh
    sudo mkdir -p "$mnt"
    if sudo mount_apfs -o ro -s "$snap" "$data_dev" "$mnt"; then
        success "Mounted. You can now browse $mnt (it is the exact clean state)."
        echo "  Example: ls $mnt/Users"
        echo "  To unmount later: diskutil unmount $mnt   (or umount $mnt)"
        echo "  (The mount is read-only — you cannot accidentally change the clean data.)"
    else
        error "Mount failed."
        echo "  Common causes for 'Operation not permitted':"
        echo "  - Trying to mount a snapshot of the live root Data volume (sometimes restricted by SIP/FileVault)."
        echo "  - Need Full Disk Access for Terminal (System Settings > Privacy & Security)."
        echo "  - Snapshot is purgeable or system-managed."
        echo "  Try manually: sudo mount_apfs -o ro -s '$snap' '$data_dev' /tmp/test-mount"
        echo "  Or use the GUI Disk Utility > View > Show APFS Snapshots to mount."
        rmdir "$mnt" 2>/dev/null || true
        return 1
    fi
}

do_create_compressed_dmg() {
    local dest_dir=${1:-}
    local custom_name=${2:-}
    local snap=${3:-}
    local src_sub=${4:-}   # optional subpath relative to the mounted snapshot, e.g. "Users/martin" or "Applications"

    if [[ -z "$snap" ]]; then
        snap=$(get_latest_snapshot)
    fi
    if [[ -z "$snap" ]]; then
        error "No snapshot to image. Create one first with --create-snapshot."
        return 1
    fi

    if [[ -z "$dest_dir" ]]; then
        dest_dir=$(get_external_choice)
    fi
    [[ -z "$dest_dir" ]] && dest_dir="$HOME/Desktop"

    mkdir -p "$dest_dir" 2>/dev/null || true

    if [[ ! -w "$dest_dir" ]]; then
        error "Destination '$dest_dir' does not appear writable."
        echo "  This often happens with external APFS volumes that have a read-only 'system' part (Sandisk) vs writable 'Data' part (Sandisk - Data)."
        echo "  Try choosing 'o' and enter a path like /Volumes/Sandisk\\ -\\ Data/Backups or create a subfolder first."
        echo "  Or use 'd' for Desktop and copy the DMG to the external later."
        return 1
    fi

    if [[ -z "$custom_name" ]]; then
        local ts
        ts=$(date +%Y-%m-%d_%H%M)
        custom_name="${DEFAULT_DMG_NAME_PREFIX}-${ts}.dmg"
    fi

    local full_path="${dest_dir}/${custom_name}"
    if [[ -e "$full_path" ]]; then
        warn "File already exists: $full_path"
        read -r -p "Overwrite? [y/N] " ans
        [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "Aborted."; return 0; }
    fi

    local data_dev=$(get_data_device)
    if [[ -z "$data_dev" ]]; then
        error "Could not determine the Data volume device node."
        return 1
    fi

    local mnt="${MOUNT_PREFIX}-dmg-$$"
    info "Preparing clean snapshot view..."
    sudo_refresh
    sudo mkdir -p "$mnt"
    sudo mount_apfs -o ro -s "$snap" "$data_dev" "$mnt" || {
        error "Failed to mount snapshot for imaging."
        echo "  (Using device $data_dev; try the manual command above if this persists.)"
        rmdir "$mnt" 2>/dev/null || true
        return 1
    }

    local src_path="$mnt"
    if [[ -n "$src_sub" ]]; then
        src_path="$mnt/$src_sub"
        if [[ ! -e "$src_path" ]]; then
            warn "Subpath $src_sub not found under snapshot. Using full snapshot root instead."
            src_path="$mnt"
        else
            info "Imaging only subpath: $src_sub (smaller DMG)"
        fi
    fi

    info "Creating compressed UDZO DMG (this may take a minute or two)..."
    info "Source: $src_path  (clean snapshot: $snap)"
    info "Destination: $full_path"

    if hdiutil create -srcfolder "$src_path" -format UDZO -o "$full_path"; then
        success "Created: $full_path"
        local size
        size=$(du -h "$full_path" 2>/dev/null | awk '{print $1}')
        info "Compressed size: ${size:-?}"

        # Write a persistent sidecar info file next to the DMG with description
        local info_file="${full_path}.info"
        local alias_for_dmg
        alias_for_dmg=$(lookup_alias "$snap")
        if [[ -z "$alias_for_dmg" && -n "$desc" ]]; then
            alias_for_dmg="$desc"
        fi
        cat > "$info_file" << EOF
Clean State Device Snapshot Archive
====================================
Snapshot Name : $snap
Alias / Description : ${alias_for_dmg:-"(none recorded)"}
Created         : $(date)
Source DMG      : $(basename "$full_path")
Data Volume     : $DATA_MOUNT
Notes           : Created via clean-state.sh for reproducible test resets.
                  Restore via Recovery > Restore from Time Machine (for local snapshots)
                  or Disk Utility Restore / asr for this DMG.
EOF
        success "Wrote sidecar metadata: $info_file (travels with the DMG on external)"

        echo
        info "You can now copy this DMG anywhere. To restore later, boot to Recovery and use Disk Utility → Restore, or:"
        echo "  asr restore --source \"$full_path\" --target /dev/diskX --erase"
        echo "  (Always run 'diskutil list' in Recovery first to confirm the target disk!)"
    else
        error "DMG creation failed."
    fi

    # Cleanup mount
    diskutil unmount "$mnt" 2>/dev/null || sudo umount "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
}

do_unmount() {
    local mnt=${1:-}
    if [[ -z "$mnt" ]]; then
        # Try to find our mounts
        mnt=$(mount | awk '/CleanSnapshot/ {print $3}' | head -1)
    fi
    if [[ -z "$mnt" ]]; then
        read -r -p "Enter mount point to unmount (e.g. /Volumes/CleanSnapshot-...): " mnt
    fi
    if [[ -n "$mnt" ]]; then
        info "Unmounting $mnt ..."
        diskutil unmount "$mnt" 2>/dev/null || sudo umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
        success "Done."
    fi
}

do_delete_snapshot() {
    local target=${1:-}
    if [[ -z "$target" ]]; then
        echo "Available snapshots:"
        list_all_snapshots | cat -n
        read -r -p "Enter number or full snapshot name to delete: " target
        if [[ "$target" =~ ^[0-9]+$ ]]; then
            target=$(list_all_snapshots | sed -n "${target}p")
        fi
    fi
    if [[ -z "$target" ]]; then
        error "No snapshot specified."
        return 1
    fi

    read -r -p "Really delete snapshot '$target'? This cannot be undone. [y/N] " ans
    if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
        info "Cancelled."
        return 0
    fi

    sudo_refresh
    if tmutil deletelocalsnapshots "$target" 2>&1; then
        success "Deleted $target"
    else
        # Fallback to diskutil by name
        local dev
        dev=$(get_data_device)
        local uuid
        uuid=$(diskutil apfs listSnapshots "$dev" 2>/dev/null | grep -B1 -A5 "$target" | awk '/^[[:space:]]*\+--/ {print $2; exit}' || true)
        if [[ -n "$uuid" ]]; then
            diskutil apfs deleteSnapshot "$dev" -uuid "$uuid"
        else
            error "Could not delete. Try: sudo tmutil deletelocalsnapshots \"$target\""
        fi
    fi
}

print_guidance() {
    cat << 'GUIDANCE'

================================================================================
                        RESTORE / REVERT GUIDANCE
================================================================================

### 1. FASTEST: Revert using a local tmutil snapshot (no external needed)
   - The snapshots created by this script (com.apple.TimeMachine....local) are
     visible to Time Machine.
   - Restart your Mac and boot to Recovery:
       • Apple silicon: Hold power button until "Loading startup options" →
         Options → Continue (enter password).
   - Choose "Restore from Time Machine Backup".
   - Select your internal drive (Macintosh HD).
   - Pick the snapshot with the date/time of your clean state.
   - Restore. Reboot. You are back to that exact clean point.

   Tip: Delete old snapshots you no longer need with this script or:
        sudo tmutil deletelocalsnapshots 2026-06-05-085501

### 2. From a compressed DMG on external drive (durable archive)
   - Connect the drive containing your CleanState-....dmg.
   - Boot to Recovery (same as above).
   - Open Disk Utility.
   - File → New Image... is for creating; instead use the Restore tab:
       - Drag your .dmg into the Source field (or click the image icon).
       - Drag the target APFS Container (show all devices, pick the big internal
         container, e.g. "Apple_APFS Container disk3") into the Destination.
       - Click Restore.
   - Or in Terminal (in Recovery):
       diskutil list     # <-- ALWAYS verify the disk numbers first!
       asr restore --source /Volumes/YourExternal/CleanState-xxx.dmg \
                    --target /dev/disk3 --erase

   WARNING: --erase wipes the target. Double-check disk identifiers every time.

### 3. Full container / bootable system image (more complete)
   For a true full-device image (System + Data + Preboot + Recovery roles):
   - Best done while booted from an external macOS install or in Recovery.
   - In Disk Utility (show all devices): right-click the internal APFS Container
     → "Image from ... Container" → choose Compressed format.
   - Or via Terminal (from Recovery or external boot):
       hdiutil create -srcdevice /dev/rdisk3 -format UDZO \
                      -o /Volumes/External/CleanFull.dmg
       asr imagescan --source /Volumes/External/CleanFull.dmg
   - Restore with asr or Disk Utility as above, targeting the container.

### 4. After restore
   - You may need to re-enable FileVault, log in, etc.
   - Local snapshots from before the restore are usually gone (new clean baseline).

================================================================================
TIPS
- Always create the snapshot *after* you have reached your exact desired clean
  state and *before* you start polluting.
- Combine both: keep 1-2 recent local snapshots for speed + a compressed DMG
  on external as the gold master.
- Your Data volume is small on this machine → compressed DMGs are tiny.
- Never rely on a single copy. Test your restore path at least once.

GUIDANCE
}

# ----------------------------- Interactive -----------------------------------
interactive_menu() {
    cleanup_stale_clean_dirs
    while true; do
        print_state

        echo "${BOLD}What would you like to do?${RESET}"
        cat << MENU
  1) Create a new snapshot (mark current state as clean)
  2) List snapshots
  3) Mount a snapshot read-only (inspect the clean state)
  4) Create compressed DMG from a snapshot (to external or Desktop)
  5) Unmount a snapshot mount
  6) Delete a snapshot
  7) Tag / give alias to an existing snapshot (persists in registry + sidecar)
  8) Show full restore guidance (Recovery steps)
  9) Refresh / show state again
  h) Help - explain what all these options (and destination choices) mean
  q) Quit
MENU

        read -r -p "Choice: " choice
        echo

        case "$choice" in
            1)
                do_create_snapshot "" "1"   # no desc, suppress tip (we prompt below instead)
                # Prompt for alias right after creation in interactive mode
                local latest
                latest=$(get_latest_snapshot)
                if [[ -n "$latest" ]]; then
                    local existing_alias
                    existing_alias=$(lookup_alias "$latest")
                    if [[ -z "$existing_alias" ]]; then
                        read -r -p "Give this snapshot an alias/description now? (optional, press Enter to skip): " newalias
                        if [[ -n "$newalias" ]]; then
                            record_alias "$latest" "$newalias"
                        fi
                    fi
                fi
                ;;
            2) do_list_snapshots ;;
            3)
                echo "Available snapshots:"
                local -a snap_list=()
                while IFS= read -r s; do
                    [[ -n "$s" ]] && snap_list+=("$s")
                done < <(list_all_snapshots)
                if [[ ${#snap_list[@]} -eq 0 ]]; then
                    error "No snapshots."
                    # fall through to press-enter and re-show menu
                fi
                local i=1
                for s in "${snap_list[@]}"; do
                    local a
                    a=$(lookup_alias "$s")
                    if [[ -n "$a" ]]; then
                        printf "  %d) %s  (Alias: %s)\n" "$i" "$s" "$a"
                    else
                        printf "  %d) %s\n" "$i" "$s"
                    fi
                    ((i++))
                done
                read -r -p "Enter number to mount (or 0 for latest): " num
                if [[ "$num" == "0" || -z "$num" ]]; then
                    do_mount_snapshot ""
                elif [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#snap_list[@]} )); then
                    do_mount_snapshot "${snap_list[$((num-1))]}"
                else
                    read -r -p "Enter exact snapshot name: " snap
                    [[ -n "$snap" ]] && do_mount_snapshot "$snap"
                fi
                ;;
            4)
                local dest snap subpath=""
                echo "Tip: at the destination prompt you can also type 'h' for help if needed."
                dest=$(get_external_choice)
                echo
                snap=$(get_latest_snapshot)
                if [[ -n "$snap" ]]; then
                    read -r -p "Use latest snapshot ($snap)? [Y/n] " ans
                    [[ "$ans" == "n" || "$ans" == "N" ]] && read -r -p "Enter snapshot name: " snap
                fi
                echo
                read -r -p "Image full Data volume, or a subfolder only? (f)ull / (h)ome / (a)pps / (c)ustom / (s)kip [f]: " subchoice
                case "$subchoice" in
                    h|H) subpath="Users" ;;
                    a|A) subpath="Applications" ;;
                    c|C) read -r -p "Enter subpath relative to snapshot root (e.g. Users/martin or Library): " subpath ;;
                    *) subpath="" ;;   # full
                esac
                do_create_compressed_dmg "$dest" "" "$snap" "$subpath"
                ;;
            5) do_unmount ;;
            6) do_delete_snapshot ;;
            7) do_tag_snapshot ;;
            8) print_guidance ;;
            9) ;;   # just loop and reprint state
            h|H|help)
                show_help
                read -r -p "Press Enter to return to the menu..." _
                ;;
            q|Q|quit|exit) echo "Bye!"; break ;;
            *) warn "Unknown choice." ;;
        esac

        echo
        read -r -p "Press Enter to continue..." _
        clear 2>/dev/null || echo "----------"
    done
}

# ----------------------------- CLI parsing -----------------------------------
usage() {
    cat << EOF
${BOLD}clean-state.sh${RESET} — Guided clean device state with tmutil snapshots + compressed DMGs

Usage:
  $(basename "$0") [options]

No arguments          Enter interactive guided menu (best for most people)
  --status            Show current disks, snapshots, space, externals
  --create-snapshot   Create a new local snapshot of the Data volume
                        --description "My clean baseline before Foo tests"
  --list-snapshots    List existing local snapshots (shows aliases if tagged)
  --mount [NAME]      Mount a snapshot read-only (latest if NAME omitted)
  --create-dmg        Create a compressed UDZO DMG from latest (or specified) snapshot
                        --dest /path/to/folder     (required for non-interactive)
                        --name MyClean.dmg
                        --snapshot "full.name.local"
                        --src Users/martin         (optional: image only this subpath for a smaller DMG)
  --tag|--tag-snapshot [NAME] [description]
                        Give an existing snapshot a human alias/description.
                        This is recorded in a local registry and written into
                        .info sidecar files next to DMGs for persistence.
  --show-registry     Display the persistent alias registry.
  --unmount [MNT]     Unmount a CleanSnapshot mount
  --delete-snapshot NAME   Delete a snapshot (by name or date)
  --guidance          Print detailed Recovery restore instructions
  --help              This help (type 'h' inside the interactive menu for the same explanations)

Examples:
  ./clean-state.sh
  ./clean-state.sh --create-snapshot
  ./clean-state.sh --create-dmg --dest /Volumes/MySSD --name "Clean-$(date +%F).dmg"
  ./clean-state.sh --mount
  ./clean-state.sh --guidance

Put the script somewhere convenient (e.g. ~/bin) and chmod +x it.
Run it regularly before tests. Keep at least one good snapshot + one DMG on external.
EOF
}

main() {
    require_macos

    if [[ $# -eq 0 ]]; then
        interactive_menu
        return
    fi

    local cmd=""
    local dest="" name="" snap="" subpath="" desc=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --status) cmd="status"; shift ;;
            --create-snapshot) cmd="create-snapshot"; shift ;;
            --description|--desc|--alias)
                desc="$2"; shift 2 ;;
            --list-snapshots) cmd="list"; shift ;;
            --mount)
                cmd="mount"
                shift
                if [[ $# -gt 0 && "$1" != --* ]]; then snap="$1"; shift; fi
                ;;
            --create-dmg)
                cmd="dmg"
                shift
                ;;
            --dest)
                dest="$2"; shift 2 ;;
            --name)
                name="$2"; shift 2 ;;
            --snapshot)
                snap="$2"; shift 2 ;;
            --src|--sub|--subpath)
                subpath="$2"; shift 2 ;;
            --unmount)
                cmd="unmount"
                shift
                if [[ $# -gt 0 && "$1" != --* ]]; then snap="$1"; shift; fi   # reuse var
                ;;
            --delete-snapshot)
                cmd="delete"
                shift
                if [[ $# -gt 0 && "$1" != --* ]]; then snap="$1"; shift; fi
                ;;
            --guidance) cmd="guidance"; shift ;;
            --show-registry|--registry)
                cmd="show-registry"; shift ;;
            --tag|--tag-snapshot)
                cmd="tag"
                shift
                if [[ $# -gt 0 && "$1" != --* ]]; then snap="$1"; shift; fi
                if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then desc="$1"; shift; fi
                ;;
            *)
                error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$cmd" in
        status) print_state ;;
        create-snapshot) do_create_snapshot "$desc" ;;
        list) do_list_snapshots ;;
        mount) do_mount_snapshot "$snap" ;;
        dmg)
            if [[ -z "$dest" ]]; then
                error "--dest is required in non-interactive mode"
                echo "Example: $0 --create-dmg --dest /Volumes/ExternalSSD"
                exit 1
            fi
            do_create_compressed_dmg "$dest" "$name" "$snap" "${subpath:-}"
            ;;
        unmount) do_unmount "$snap" ;;
        delete) do_delete_snapshot "$snap" ;;
        guidance) print_guidance ;;
        tag) do_tag_snapshot "$snap" "$desc" ;;
        show-registry)
            if [[ -f "$REGISTRY_FILE" ]]; then
                cat "$REGISTRY_FILE"
            else
                echo "No registry file yet."
            fi
            ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
