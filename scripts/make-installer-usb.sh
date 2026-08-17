#!/usr/bin/env bash
# Build an Anaconda-based installer ISO from a bootc image (default: the
# desktop flavor) with bootc-image-builder, then write it to a USB stick.
# See README.md "Fresh bare metal / VM" for the manual equivalent of the
# build step this script automates.
set -euo pipefail

IMAGE="ghcr.io/eelcoh/bootsy-linux/desktop:latest"
OUTPUT_DIR="./output"
DEVICE=""
USERNAME=""
SSH_KEY_FILE=""
HOSTNAME=""
TIMEZONE=""
# quay.io/fedora/fedora-bootc:44 (what base/Containerfile builds from) ships
# no /usr/lib/bootc/install.toml, so bootc-image-builder has no default
# root-fs-type to fall back on and errors out unless --rootfs is given
# explicitly. ext4 is Fedora's conventional bootc choice (RHEL/CentOS bootc
# images default to xfs instead).
ROOTFS="ext4"

usage() {
	cat <<-EOF
	Usage: $(basename "$0") -d /dev/sdX -u USERNAME [-k SSH_KEY_FILE] [-n HOSTNAME] [-z TIMEZONE] [-i IMAGE] [-o OUTPUT_DIR] [-r ROOTFS]

	  -d DEVICE      USB block device to write the installer to (e.g. /dev/sdb).
	                 REQUIRED. The whole device is overwritten, not a partition.
	  -u USERNAME    Login account to create on the installed system (added to
	                 the wheel group for sudo). REQUIRED: neither image in this
	                 repo creates a user or sets a root password on its own
	                 (see base/Containerfile), so without this the installer
	                 produces a system nothing can log into. You'll be
	                 prompted for the password interactively.
	  -k SSH_KEY_FILE  Path to a public SSH key file to authorize for USERNAME.
	  -n HOSTNAME    Hostname for the installed system. bootc-image-builder's
	                 config.toml has no effect on this for ISO builds (its
	                 kickstart generator never reads a hostname customization),
	                 so when given, this script switches to writing a full
	                 custom kickstart body instead (see below) rather than
	                 leaving every install as "fedora".
	  -z TIMEZONE    Timezone for the installed system, e.g. Europe/Amsterdam
	                 (see `timedatectl list-timezones`). Same config.toml
	                 limitation as -n; also switches to a custom kickstart
	                 body. Default when a custom kickstart is needed but -z
	                 is omitted: UTC.
	  -i IMAGE       bootc image reference to build an installer for.
	                 Default: ${IMAGE}
	  -o OUTPUT_DIR  Directory bootc-image-builder writes the ISO into.
	                 Default: ${OUTPUT_DIR}
	  -r ROOTFS      Root filesystem type for the installed system (ext4, xfs, btrfs).
	                 Default: ${ROOTFS}
	  -h             Show this help.

	Example:
	  $(basename "$0") -d /dev/sdb -u eelco
	  $(basename "$0") -d /dev/sdb -u eelco -k ~/.ssh/id_ed25519.pub -i ghcr.io/eelcoh/bootsy-linux/server:latest
	  $(basename "$0") -d /dev/sdb -u eelco -n mybox -z Europe/Amsterdam
	EOF
}

while getopts ":d:u:k:n:z:i:o:r:h" opt; do
	case "$opt" in
	d) DEVICE="$OPTARG" ;;
	u) USERNAME="$OPTARG" ;;
	k) SSH_KEY_FILE="$OPTARG" ;;
	n) HOSTNAME="$OPTARG" ;;
	z) TIMEZONE="$OPTARG" ;;
	i) IMAGE="$OPTARG" ;;
	o) OUTPUT_DIR="$OPTARG" ;;
	r) ROOTFS="$OPTARG" ;;
	h)
		usage
		exit 0
		;;
	\?)
		echo "Unknown option: -$OPTARG" >&2
		usage
		exit 1
		;;
	:)
		echo "Option -$OPTARG requires an argument" >&2
		usage
		exit 1
		;;
	esac
done

if [[ -z "$DEVICE" ]]; then
	echo "error: -d DEVICE is required" >&2
	usage
	exit 1
fi

if [[ -z "$USERNAME" ]]; then
	echo "error: -u USERNAME is required (see -h) — without it the installed system has no way to log in" >&2
	usage
	exit 1
fi

if [[ -n "$HOSTNAME" && ! "$HOSTNAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "error: -n HOSTNAME must contain only letters, digits, '.', and '-' (it's written unquoted into a kickstart line)" >&2
	exit 1
fi

if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
	echo "error: SSH key file $SSH_KEY_FILE not found" >&2
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "error: must run as root (bootc-image-builder needs --privileged podman, and writing to a raw block device needs root)" >&2
	exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
	echo "error: $DEVICE is not a block device" >&2
	exit 1
fi

# Refuse to touch whatever disk the running system's root filesystem lives
# on, so a typo in -d can't brick the machine running this script.
ROOT_SRC="$(findmnt -no SOURCE / )"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
DEVICE_NAME="$(basename "$DEVICE")"
if [[ -n "$ROOT_DISK" && "$DEVICE_NAME" == "$ROOT_DISK" ]]; then
	echo "error: $DEVICE appears to be the disk the running system is booted from. Refusing." >&2
	exit 1
fi

echo "== Target device =="
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$DEVICE"
echo
read -r -p "This will ERASE ALL DATA on $DEVICE. Type the device path to confirm: " CONFIRM
if [[ "$CONFIRM" != "$DEVICE" ]]; then
	echo "Confirmation did not match $DEVICE. Aborting." >&2
	exit 1
fi

# Unmount any mounted partitions on the target device first. -r (raw) is
# required here: lsblk's default NAME column is tree-formatted for child
# devices (e.g. "└─sdb1"), which would otherwise get fed straight into
# umount as a bogus path like "/dev/└─sdb1" and, under set -e, kill the
# script every time the stick has a mounted partition.
for part in $(lsblk -rno NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}'); do
	echo "Unmounting /dev/$part"
	umount "/dev/$part"
done

read -r -s -p "Password for $USERNAME: " USER_PASSWORD
echo
read -r -s -p "Confirm password: " USER_PASSWORD_CONFIRM
echo
if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
	echo "error: passwords did not match" >&2
	exit 1
fi
if [[ ( -n "$HOSTNAME" || -n "$TIMEZONE" ) && "$USER_PASSWORD" == *'"'* ]]; then
	# -n/-z switch this script to writing a raw kickstart body (see below),
	# where the password is embedded inside a double-quoted --password="..."
	# argument; an embedded '"' would truncate that argument and corrupt the
	# kickstart rather than fail loudly, so refuse instead of risking that.
	echo 'error: password cannot contain a " character when -n/-z is used (it is embedded in a kickstart --password="..." argument)' >&2
	exit 1
fi
unset USER_PASSWORD_CONFIRM

mkdir -p "$OUTPUT_DIR"

CONFIG_FILE="$(mktemp)"
cleanup() { rm -f "$CONFIG_FILE"; }
trap cleanup EXIT

# bootc-image-builder's --type iso path never applies hostname or timezone
# customizations from config.toml: the blueprint's Timezone/Language/Keyboard
# fields get parsed into its kickstart generator's Options struct but nothing
# ever assigns them from there, and hostname isn't even represented in that
# struct at all (verified in its source, both in osbuild/bootc-image-builder
# and osbuild/images). The ISO path's default kickstart hardcodes
# "UTC"/"en_US.UTF-8"/"us"/"fedora" itself instead of reading the blueprint.
#
# The only thing that reliably works is a full custom kickstart body via
# [customizations.installer.kickstart]. bootc-image-builder %includes its own
# ostree/bootc setup *from* that body rather than the other way around, and
# skips its own partitioning/locale/network/timezone/root-password defaults
# entirely once a custom body is present - so when -n/-z is used, this script
# has to supply all of that itself, not just the extra hostname/timezone
# lines. See README.md "Fresh bare metal / VM" for the full explanation.
{
	if [[ -n "$HOSTNAME" || -n "$TIMEZONE" ]]; then
		KS_HOSTNAME_OPT=""
		if [[ -n "$HOSTNAME" ]]; then
			KS_HOSTNAME_OPT=" --hostname=$HOSTNAME"
		fi
		KS_TIMEZONE="${TIMEZONE:-UTC}"
		KS_BODY=$(cat <<-KSEOF
			zerombr
			clearpart --all --initlabel
			autopart
			lang en_US.UTF-8
			keyboard us
			network --bootproto=dhcp --activate --onboot=on${KS_HOSTNAME_OPT}
			timezone ${KS_TIMEZONE} --utc
			rootpw --lock
			user --name="${USERNAME}" --password="${USER_PASSWORD}" --groups=wheel
			KSEOF
		)
		if [[ -n "$SSH_KEY_FILE" ]]; then
			KS_BODY="${KS_BODY}"$'\n'"sshkey --username=\"${USERNAME}\" \"$(cat "$SSH_KEY_FILE")\""
		fi
		echo "[customizations.installer.kickstart]"
		echo "contents = '''"
		echo "$KS_BODY"
		echo "'''"
	else
		echo "[[customizations.user]]"
		echo "name = \"$USERNAME\""
		echo "password = \"$USER_PASSWORD\""
		if [[ -n "$SSH_KEY_FILE" ]]; then
			printf 'key = "%s"\n' "$(cat "$SSH_KEY_FILE")"
		fi
		echo 'groups = ["wheel"]'
	fi
} >"$CONFIG_FILE"
unset USER_PASSWORD
chmod 600 "$CONFIG_FILE"
echo "== Building installer ISO for $IMAGE =="
podman run --rm -it --privileged \
	--pull=newer \
	--security-opt label=type:unconfined_t \
	-v "$CONFIG_FILE:/config.toml:ro" \
	-v "$OUTPUT_DIR:/output" \
	-v /var/lib/containers/storage:/var/lib/containers/storage \
	quay.io/centos-bootc/bootc-image-builder:latest \
	--type iso \
	--rootfs "$ROOTFS" \
	"$IMAGE"

mapfile -t ISOS < <(find "$OUTPUT_DIR" -name '*.iso')
if [[ ${#ISOS[@]} -ne 1 ]]; then
	echo "error: expected exactly one .iso under $OUTPUT_DIR, found ${#ISOS[@]}: ${ISOS[*]:-none}" >&2
	exit 1
fi
ISO="${ISOS[0]}"
echo "Built $ISO"

echo "== Writing $ISO to $DEVICE =="
# No oflag=direct: it forces every block to complete synchronously on the
# device with no write-behind buffering, which is much slower than plain
# buffered writes on most USB flash controllers. conv=fsync + the explicit
# sync below still guarantee the script doesn't exit before data has
# actually reached the device.
dd if="$ISO" of="$DEVICE" bs=4M status=progress conv=fsync
sync

DONE_MSG="Done. $DEVICE now boots the $IMAGE installer, which creates login user '$USERNAME' (wheel/sudo)"
if [[ -n "$HOSTNAME" || -n "$TIMEZONE" ]]; then
	DONE_MSG="$DONE_MSG, hostname '${HOSTNAME:-fedora}', timezone '${TIMEZONE:-UTC}',"
fi
echo "$DONE_MSG during install."
