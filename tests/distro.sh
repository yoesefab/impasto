#!/bin/bash
# Plans for Ubuntu, with the package tools replaced by stubs.
# Nothing is installed. A fake os-release selects the distro.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/home" "$work/state" "$work/os" "$work/root"

cat > "$work/bin/apt-get" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
exit 0
EOF
cat > "$work/bin/apt-cache" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
if [[ ${1:-} == policy ]]; then
    printf 'Candidate: (none)\n'
fi
exit 0
EOF
cat > "$work/bin/dpkg-query" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
exit 1
EOF
cat > "$work/bin/add-apt-repository" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
exit 0
EOF
cat > "$work/bin/hyprland" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --version ]]; then
    printf 'Hyprland %s built from commit abc\n' "${IMPASTO_HYPRLAND_VERSION:-0.56.1}"
fi
exit 0
EOF
cat > "$work/bin/plymouth-set-default-theme" <<'EOF'
#!/bin/bash
printf 'bgrt\n'
exit 0
EOF
cat > "$work/bin/update-initramfs" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$work/bin/update-grub" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$work/bin/"*

cat > "$work/os/ubuntu" <<'EOF'
NAME="Ubuntu"
ID=ubuntu
ID_LIKE=debian
VERSION_ID=24.04
EOF
cat > "$work/os/arch" <<'EOF'
NAME="Arch Linux"
ID=arch
ID_LIKE=archlinux
EOF
cat > "$work/os/fedora" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
EOF
cat > "$work/os/debian" <<'EOF'
NAME="Debian GNU/Linux"
ID=debian
ID_LIKE=debian
EOF

theme="$work/root/usr/share/plymouth/themes/impasto"
mkdir -p "$theme" "$work/root/etc/default/grub.d"
printf 'theme\n' > "$theme/impasto.plymouth"
printf 'splash\n' > "$work/root/etc/default/grub.d/impasto.cfg"

run_setup() {
    local release=$1
    shift
    IMPASTO_LOG=$work/log
    : > "$IMPASTO_LOG"
    env -u SUDO_ASKPASS \
        HOME="$work/home" \
        XDG_STATE_HOME="$work/state" \
        IMPASTO_OS_RELEASE="$work/os/$release" \
        IMPASTO_ROOT="$work/root" \
        IMPASTO_LOG="$IMPASTO_LOG" \
        IMPASTO_HYPRLAND_VERSION="${IMPASTO_HYPRLAND_VERSION:-}" \
        PATH="$work/bin:/usr/bin:/bin" \
        "$root/setup" "$@"
}

echo "ubuntu plans apt and keeps hyprland 0.56"
ubuntu_out=$(run_setup ubuntu packages --dry-run --noconfirm)
grep -q '── apt' <<<"$ubuntu_out"
grep -q 'kept     hyprland 0.56.1' <<<"$ubuntu_out"
grep -q 'would build quickshell from source into /usr/local' <<<"$ubuntu_out"
grep -q 'would enable ppa:cppiber/hyprland' <<<"$ubuntu_out"
if grep -q 'for: hyprland ' <<<"$ubuntu_out" || grep -q 'for: hyprland$' <<<"$ubuntu_out"; then
    echo "ubuntu offered the PPA a new enough hyprland" >&2
    exit 1
fi
if grep -q 'install -y' "$work/log"; then
    echo "dry-run invoked apt-get install" >&2
    cat "$work/log" >&2
    exit 1
fi

echo "ubuntu leaves an older hyprland installed"
old_out=$(IMPASTO_HYPRLAND_VERSION=0.51.0 run_setup ubuntu packages --dry-run --noconfirm)
grep -q 'left     hyprland 0.51.0' <<<"$old_out"
if grep -q 'would install hyprland' <<<"$old_out"; then
    echo "ubuntu offered to replace an older hyprland" >&2
    exit 1
fi

echo "arch, fedora and debian are refused"
for release in arch fedora debian; do
    if run_setup "$release" packages --dry-run --noconfirm >"$work/refused.out" 2>"$work/refused.err"; then
        echo "$release was accepted" >&2
        exit 1
    fi
    grep -q 'impasto installs on Ubuntu' "$work/refused.err"
done

echo "ubuntu splash uses update-initramfs"
splash_out=$(run_setup ubuntu splash --dry-run --noconfirm)
grep -q 'initramfs with update-initramfs' <<<"$splash_out"
if grep -q 'mkinitcpio\|dracut' <<<"$splash_out"; then
    echo "ubuntu splash mentioned another initramfs tool" >&2
    exit 1
fi

echo "ubuntu system files copy the grub drop-in"
system_out=$(run_setup ubuntu system --dry-run --noconfirm)
grep -q 'etc/default/grub.d/impasto.cfg' <<<"$system_out"
if grep -q 'mkinitcpio\|dracut' <<<"$system_out"; then
    echo "ubuntu deploy copied an initramfs drop-in this fork does not ship" >&2
    exit 1
fi

echo "distro plans ok"
