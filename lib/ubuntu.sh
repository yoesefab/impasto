# Ubuntu half of ./setup. Sourced by setup; not run on its own.
# This fork installs on Ubuntu only. /etc/os-release must say ID=ubuntu.

DISTRO=unknown
DISTRO_ID=
DISTRO_VERSION=
OS_RELEASE=${IMPASTO_OS_RELEASE:-/etc/os-release}
HYPRLAND_KEEP=0
HYPRLAND_PPA=ppa:cppiber/hyprland

read_distro() {
    DISTRO=unknown
    DISTRO_ID=
    DISTRO_VERSION=
    [[ -f $OS_RELEASE ]] || return 0
    local key value id= like= version=
    while IFS='=' read -r key value || [[ -n $key ]]; do
        [[ $key == '#'* || -z $key ]] && continue
        value=${value%\"}
        value=${value#\"}
        value=${value%$'\r'}
        case $key in
            ID) id=$value ;;
            ID_LIKE) like=$value ;;
            VERSION_ID) version=$value ;;
        esac
    done < "$OS_RELEASE"
    DISTRO_ID=$id
    DISTRO_VERSION=$version
    # ID_LIKE=debian is Debian and every derivative. Only Ubuntu itself.
    if [[ $id == ubuntu ]]; then
        DISTRO=ubuntu
    fi
}

# Nothing under system/ is distro-specific any more: the GRUB drop-in is
# the one Ubuntu's grub-mkconfig sources, and there is no mkinitcpio or dracut file.
distro_skips() {
    return 1
}

desk_line() {
    printf 'a desk for Ubuntu and Hyprland'
}

# One name a line. $2 is required, optional or all. A leading `?` marks
# an optional name; `#` comments are dropped first.
manifest_names() {
    local file=$1 which=${2:-all} line mark
    [[ -f $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n $line ]] || continue
        mark=required
        if [[ $line == '?'* ]]; then
            mark=optional
            line=${line#\?}
            line=${line#"${line%%[![:space:]]*}"}
        fi
        [[ -n $line ]] || continue
        [[ $which == all || $which == "$mark" ]] || continue
        printf '%s\n' "$line"
    done < "$file"
}

# $1 installed, $2 minimum. Equal counts as new enough. Non-numeric tails
# (ubuntu revisions, ppa suffixes) are ignored after the dotted numbers.
version_at_least() {
    local IFS=.
    local -a got want
    read -ra got <<< "${1%%[^0-9.]*}"
    read -ra want <<< "${2%%[^0-9.]*}"
    local i n=${#got[@]} x y
    (( ${#want[@]} > n )) && n=${#want[@]}
    for (( i = 0; i < n; i++ )); do
        x=${got[i]:-0}
        y=${want[i]:-0}
        x=${x//[^0-9]/}
        y=${y//[^0-9]/}
        [[ -n $x ]] || x=0
        [[ -n $y ]] || y=0
        if (( 10#$x > 10#$y )); then return 0; fi
        if (( 10#$x < 10#$y )); then return 1; fi
    done
    return 0
}

hyprland_version() {
    local line=
    if command -v hyprland >/dev/null; then
        line=$(hyprland --version 2>/dev/null | head -1) || true
    elif command -v hyprctl >/dev/null; then
        line=$(hyprctl version 2>/dev/null | head -1) || true
    fi
    [[ $line =~ ([0-9]+\.[0-9]+([.][0-9]+)?) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

quickshell_version() {
    local bin line=
    for bin in qs quickshell; do
        command -v "$bin" >/dev/null || continue
        line=$("$bin" --version 2>&1 | head -1) || true
        [[ $line =~ ([0-9]+\.[0-9]+([.][0-9]+)?) ]] || continue
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    done
    return 1
}

# Drop a Debian epoch so 1:2.3.4 compares as 2.3.4.
apt_upstream() {
    local version=$1
    version=${version#*:}
    printf '%s' "$version"
}

apt_has() {
    dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# The candidate version, or nothing when the archive does not have the name.
apt_candidate() {
    local out
    out=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')
    [[ -n $out && $out != '(none)' ]] || return 1
    printf '%s' "$out"
}

# Names from the arguments that apt can see.
apt_which_available() {
    local name cand
    for name in "$@"; do
        cand=$(apt_candidate "$name" || true)
        [[ -n $cand ]] || continue
        printf '%s\n' "$name"
    done
}

# Names ./setup installs itself, so the optional pass does not race them.
ubuntu_special() {
    case $1 in
        hyprland|hyprland-dev|hyprpm|quickshell|awww|swww) return 0 ;;
    esac
    return 1
}

ubuntu_apt_install() {
    local -a pkgs=("$@")
    local pkg
    (( ${#pkgs[@]} )) || return 0
    if (( DRY )); then
        say "would install ${pkgs[*]}"
        return 0
    fi
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"; then
        return 0
    fi
    for pkg in "${pkgs[@]}"; do
        apt_has "$pkg" && continue
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            :
        else
            say "skipped  $pkg — apt would not take it"
        fi
    done
}

verb_packages_ubuntu() {
    command -v apt-get >/dev/null || fail 'apt-get is not installed'
    local -a want missing optional installable check
    local name

    section apt
    mapfile -t want < <(manifest_names "$REPO/packages/apt.txt" required)
    missing=()
    for name in "${want[@]}"; do
        apt_has "$name" || missing+=("$name")
    done
    if (( ${#missing[@]} )); then
        say "missing: ${missing[*]}"
        ubuntu_apt_install "${missing[@]}"
    else
        say "all ${#want[@]} installed"
    fi

    section 'ubuntu extras'
    say 'checking optional packages'
    mapfile -t optional < <(manifest_names "$REPO/packages/apt.txt" optional)
    check=()
    installable=()
    for name in "${optional[@]}"; do
        ubuntu_special "$name" && continue
        apt_has "$name" && continue
        check+=("$name")
    done
    if (( ${#check[@]} )); then
        if (( DRY )); then
            say "would look for: ${check[*]}"
        else
            mapfile -t installable < <(apt_which_available "${check[@]}")
        fi
    fi
    if (( ${#installable[@]} )); then
        say "missing: ${installable[*]}"
        ubuntu_apt_install "${installable[@]}"
    elif (( DRY && ${#check[@]} )); then
        :
    elif (( ! ${#optional[@]} )); then
        say 'nothing optional listed'
    else
        say 'nothing more in the Ubuntu repositories'
    fi

    ubuntu_hyprland
    ubuntu_ppa
    ubuntu_hyprland_after
    ubuntu_quickshell
    ubuntu_wallpaper
    ubuntu_starship
    ubuntu_nerd_font
    ubuntu_note_apps
    ubuntu_still_missing
}

ubuntu_hyprland() {
    local ver cand
    ver=$(hyprland_version || true)
    if [[ -n $ver ]]; then
        HYPRLAND_KEEP=1
        if version_at_least "$ver" 0.56; then
            say "kept     hyprland $ver"
        else
            say "left     hyprland $ver — Impasto needs 0.56 or newer, and this one stays"
        fi
        return 0
    fi
    cand=$(apt_candidate hyprland || true)
    if [[ -n $cand ]] && version_at_least "$(apt_upstream "$cand")" 0.56; then
        if (( DRY )); then
            say "would install hyprland $(apt_upstream "$cand")"
            HYPRLAND_KEEP=1
            return 0
        fi
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y hyprland; then
            HYPRLAND_KEEP=1
            say "installed hyprland $(apt_upstream "$cand")"
        fi
    fi
}

ubuntu_hyprland_after() {
    local ver
    (( HYPRLAND_KEEP )) && return 0
    ver=$(hyprland_version || true)
    if [[ -z $ver ]]; then
        say 'skipped  hyprland — no Ubuntu build of 0.56 or newer could be installed'
        return 0
    fi
    if version_at_least "$ver" 0.56; then
        HYPRLAND_KEEP=1
        say "installed hyprland $ver"
    else
        HYPRLAND_KEEP=1
        say "left     hyprland $ver — Impasto needs 0.56 or newer, and this one stays"
    fi
}

# Official Ubuntu 24.04 has no Hyprland, and 26.04's is older than 0.56.
# This PPA publishes 0.56 for those releases. It is left enabled so later
# updates come from the same place.
ubuntu_ppa() {
    local -a want=(hyprland xdg-desktop-portal-hyprland hyprpicker hyprsunset satty swww hyprcursor hyprpm)
    local -a need=()
    local pkg cand
    [[ -n $HYPRLAND_PPA ]] || return 0
    for pkg in "${want[@]}"; do
        [[ $pkg == hyprland && $HYPRLAND_KEEP == 1 ]] && continue
        apt_has "$pkg" && continue
        command -v "$pkg" >/dev/null 2>&1 && continue
        need+=("$pkg")
    done
    (( ${#need[@]} )) || return 0
    if (( DRY )); then
        say "would enable $HYPRLAND_PPA for: ${need[*]}"
        return 0
    fi
    if ! command -v add-apt-repository >/dev/null; then
        say "skipped  $HYPRLAND_PPA — add-apt-repository is not installed"
        return 0
    fi
    if ! sudo add-apt-repository -y "$HYPRLAND_PPA"; then
        say "skipped  $HYPRLAND_PPA could not be enabled"
        return 0
    fi
    sudo apt-get update -y || true
    for pkg in "${need[@]}"; do
        cand=$(apt_candidate "$pkg" || true)
        [[ -n $cand ]] || continue
        if [[ $pkg == hyprland ]] && ! version_at_least "$(apt_upstream "$cand")" 0.56; then
            say "skipped  hyprland $cand — Impasto needs 0.56 or newer"
            continue
        fi
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            say "installed $pkg from $HYPRLAND_PPA"
            [[ $pkg == hyprland ]] && HYPRLAND_KEEP=1
        else
            say "skipped  $pkg from $HYPRLAND_PPA did not install"
        fi
    done
}

ubuntu_quickshell() {
    local ver tag src cand
    ver=$(quickshell_version || true)
    if [[ -n $ver ]] && version_at_least "$ver" 0.3; then
        say "kept     quickshell $ver"
        return 0
    fi
    cand=$(apt_candidate quickshell || true)
    if [[ -n $cand ]] && version_at_least "$(apt_upstream "$cand")" 0.3; then
        if (( DRY )); then
            say "would install quickshell $(apt_upstream "$cand")"
            return 0
        fi
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y quickshell; then
            say "installed quickshell $(apt_upstream "$cand")"
            return 0
        fi
    fi
    ver=$(quickshell_version || true)
    if [[ -n $ver ]]; then
        say "quickshell $ver is older than 0.3 — building 0.3 against this system's Qt"
    else
        say 'quickshell is not installed — building 0.3 against this system'"'"'s Qt'
    fi
    if (( DRY )); then
        say 'would build quickshell from source into /usr/local'
        return 0
    fi
    local -a deps=(cmake ninja-build g++ git qt6-base-dev qt6-declarative-dev
        qt6-wayland-dev qt6-svg-dev libwayland-dev wayland-protocols
        libgl-dev libjemalloc-dev libunwind-dev libpam0g-dev pkgconf)
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${deps[@]}" || {
        say 'skipped  quickshell build dependencies are not available'
        return 0
    }
    tag=$(git ls-remote --tags https://github.com/quickshell-mirror/quickshell 'v0.3*' \
        | awk -F/ '{print $NF}' | sed 's/\^{}//' | sort -uV | tail -1)
    [[ -n $tag ]] || tag=v0.3.0
    src=$STATE/src/quickshell
    rm -rf "$src"
    if ! git clone -q --depth=1 --branch "$tag" https://github.com/quickshell-mirror/quickshell "$src"; then
        say 'skipped  quickshell could not be cloned'
        return 0
    fi
    if cmake -S "$src" -B "$src/build" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DVENDOR_CPPTRACE=ON \
        && cmake --build "$src/build" \
        && sudo cmake --install "$src/build"; then
        say "built    quickshell $tag"
    else
        say 'skipped  quickshell did not build — the desk needs qs 0.3 or newer'
    fi
}

ubuntu_wallpaper() {
    local dest src
    if command -v awww >/dev/null && command -v awww-daemon >/dev/null; then
        say 'kept     awww'
        return 0
    fi
    if command -v swww >/dev/null; then
        if (( DRY )); then
            say 'would install awww wrappers for swww'
            return 0
        fi
        dest=/usr/local/bin
        sudo install -m 755 "$REPO/lib/awww" "$dest/awww"
        sudo install -m 755 "$REPO/lib/awww-daemon" "$dest/awww-daemon"
        say 'installed awww wrappers for swww'
        return 0
    fi
    if (( DRY )); then
        say 'would build awww from source into /usr/local'
        return 0
    fi
    if ! command -v cargo >/dev/null; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cargo rustc pkg-config libwayland-dev >/dev/null \
            || { say 'skipped  awww — cargo is not installed'; return 0; }
    fi
    src=$STATE/src/awww
    rm -rf "$src"
    if ! git clone -q --depth=1 https://github.com/LGFae/awww "$src"; then
        say 'skipped  awww could not be cloned'
        return 0
    fi
    if ! (cd "$src" && cargo build --release); then
        say 'skipped  awww did not build — the wallpaper stays on the last still image'
        return 0
    fi
    dest=/usr/local/bin
    if [[ -x $src/target/release/awww && -x $src/target/release/awww-daemon ]]; then
        sudo install -m 755 "$src/target/release/awww" "$dest/awww"
        sudo install -m 755 "$src/target/release/awww-daemon" "$dest/awww-daemon"
        say 'built    awww'
        return 0
    fi
    if [[ -x $src/target/release/swww ]]; then
        sudo install -m 755 "$src/target/release/swww" "$dest/swww"
        if [[ -x $src/target/release/swww-daemon ]]; then
            sudo install -m 755 "$src/target/release/swww-daemon" "$dest/swww-daemon"
        fi
        sudo install -m 755 "$REPO/lib/awww" "$dest/awww"
        sudo install -m 755 "$REPO/lib/awww-daemon" "$dest/awww-daemon"
        say 'built    swww, with awww wrappers'
        return 0
    fi
    say 'skipped  awww did not build — the wallpaper stays on the last still image'
}

ubuntu_nerd_font() {
    if command -v fc-list >/dev/null && fc-list : family 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'; then
        say 'kept     JetBrainsMono Nerd Font'
        return 0
    fi
    if (( DRY )); then
        say 'would install JetBrainsMono Nerd Font'
        return 0
    fi
    command -v curl >/dev/null || { say 'skipped  JetBrainsMono Nerd Font — curl is not installed'; return 0; }
    local dest=${XDG_DATA_HOME:-$HOME/.local/share}/fonts/JetBrainsMonoNerd tag url
    mkdir -p "$dest"
    for tag in v3.4.0 v3.3.0 v3.2.1; do
        url="https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/JetBrainsMono.tar.xz"
        if curl -fsSL -o "$dest/font.tar.xz" "$url" \
            && tar -xJf "$dest/font.tar.xz" -C "$dest"; then
            rm -f "$dest/font.tar.xz"
            command -v fc-cache >/dev/null && fc-cache -f "$dest" >/dev/null 2>&1 || true
            say "installed JetBrainsMono Nerd Font $tag"
            return 0
        fi
        rm -f "$dest/font.tar.xz"
    done
    say 'skipped  JetBrainsMono Nerd Font could not be downloaded'
}

ubuntu_starship() {
    command -v starship >/dev/null && { say 'kept     starship'; return 0; }
    if (( DRY )); then
        say 'would install starship from its upstream installer, if no package provides it'
        return 0
    fi
    command -v curl >/dev/null || { say 'skipped  starship — curl is not installed'; return 0; }
    if curl -fsSL https://starship.rs/install.sh | sh -s -- -y; then
        say 'installed starship'
    else
        say 'skipped  starship — not in the Ubuntu repositories'
    fi
}

ubuntu_still_missing() {
    (( DRY )) && return 0
    local name
    for name in hyprpicker hyprsunset satty yazi fastfetch; do
        command -v "$name" >/dev/null || say "skipped  $name — not installed"
    done
}

ubuntu_note_apps() {
    command -v codium >/dev/null || say 'skipped  VSCodium — install the upstream deb, then ./setup vscodium'
    if ! command -v zen >/dev/null && ! command -v zen-browser >/dev/null; then
        say 'skipped  Zen — not in the Ubuntu repositories'
    fi
    command -v vesktop >/dev/null || say 'skipped  Vesktop — not in the Ubuntu repositories'
    if ! command -v spotify >/dev/null; then
        say 'skipped  Spotify — a snap or Flatpak build is not themed by ./setup spotify'
    elif ! command -v spicetify >/dev/null; then
        say 'skipped  spicetify — not in the Ubuntu repositories'
    fi
    command -v quickemu >/dev/null || say 'skipped  quickemu — not in the Ubuntu repositories'
}

# The library Hyprland is already running, under its versioned name.
ubuntu_versioned_lib() {
    local name=$1 line so candidate
    while IFS= read -r line; do
        [[ $line == *"lib${name}.so."* ]] || continue
        so=${line##* }
        [[ -e $so ]] || continue
        printf '%s\n' "$so"
        return 0
    done < <(ldconfig -p 2>/dev/null || true)
    for candidate in /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu \
            /usr/lib /usr/local/lib /usr/local/lib/x86_64-linux-gnu; do
        [[ -d $candidate ]] || continue
        so=$(find "$candidate" -maxdepth 1 -name "lib${name}.so.*" -print -quit 2>/dev/null || true)
        if [[ -n $so && -e $so ]]; then
            printf '%s\n' "$so"
            return 0
        fi
    done
    return 1
}

# hyprpm links with -laquamarine. A packaged Hyprland ships the versioned
# library and often no unversioned name. Point the linker at the one that
# is already loaded.
ubuntu_link_libs() {
    [[ ${DISTRO:-} == ubuntu ]] || return 0
    local name so dir base linkdir
    linkdir=${STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/impasto}/link
    if (( DRY )); then
        say 'would point the linker at the Hyprland libraries already in use'
        return 0
    fi
    mkdir -p "$linkdir"
    for name in aquamarine hyprutils hyprgraphics hyprlang hyprcursor; do
        [[ -e /usr/lib/x86_64-linux-gnu/lib${name}.so || -e /usr/lib/lib${name}.so \
            || -e /usr/lib/aarch64-linux-gnu/lib${name}.so ]] && continue
        so=$(ubuntu_versioned_lib "$name" || true)
        if [[ -z $so ]]; then
            say "skipped  lib${name}.so — Hyprland's package did not ship that library"
            continue
        fi
        dir=$(dirname "$so")
        base=$(basename "$so")
        ln -sfn "$so" "$linkdir/lib${name}.so"
        if [[ ! -e $dir/lib${name}.so ]]; then
            ${SUDO:-sudo} ln -sfn "$base" "$dir/lib${name}.so" || true
        fi
        say "linked   lib${name}.so → $base"
    done
    export LIBRARY_PATH="${linkdir}${LIBRARY_PATH:+:$LIBRARY_PATH}"
}

ubuntu_plugin_deps() {
    [[ $DISTRO == ubuntu ]] || return 0
    command -v apt-get >/dev/null || return 0
    local -a need=() name
    for name in cmake meson g++ git cpio pkgconf pkg-config make ninja-build; do
        apt_has "$name" && continue
        need+=("$name")
    done
    if (( ${#need[@]} )); then
        say "missing: ${need[*]}"
        if (( ! DRY )); then ubuntu_apt_install "${need[@]}"; fi
    fi
    command -v hyprpm >/dev/null || \
        say 'skipped  hyprpm — the Hyprland package did not ship it, so the plugins wait'
}

ubuntu_i2c_group() {
    [[ $DISTRO == ubuntu ]] || return 0
    [[ -z ${ROOT:-} ]] || return 0
    getent group i2c >/dev/null 2>&1 || return 0
    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then return 0; fi
    if act ${SUDO:-sudo} usermod -aG i2c "$USER"; then
        say "added    $USER to the i2c group — external monitor brightness applies at the next login"
    else
        say 'skipped  could not add this user to the i2c group'
    fi
}

# The virtual camera is opt-in. v4l2loopback-dkms is in Ubuntu's universe
# repository. MediaPipe is not; pip supplies it when apt does not.
ubuntu_install_camera() {
    local headers=linux-headers-$(uname -r)
    local -a pkgs=(v4l2loopback-dkms python3-numpy python3-opencv)
    if apt_candidate "$headers" >/dev/null; then
        pkgs+=("$headers")
    fi
    if (( DRY )); then
        say "would install ${pkgs[*]}"
        say 'would install MediaPipe with pip when apt has no python3-mediapipe'
        return 0
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || return 1
    if ! python3 -c 'import mediapipe' 2>/dev/null; then
        if apt_candidate python3-mediapipe >/dev/null; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-mediapipe || return 1
        elif python3 -m pip --version >/dev/null 2>&1; then
            python3 -m pip install --user mediapipe || return 1
        else
            return 1
        fi
    fi
    return 0
}

# The boot splash. The theme is in system/, the kernel argument is the GRUB
# drop-in, and Ubuntu rebuilds the initramfs with update-initramfs.
verb_splash() {
    local base=${ROOT:-/}
    section 'boot splash'
    if [[ -n ${ROOT:-} ]] && (( ! DRY )); then
        refuse 'the boot splash is set up on the machine itself, not under a prefix' || return
    fi
    command -v plymouth-set-default-theme >/dev/null || refuse 'plymouth is not installed (package: plymouth)' || return
    command -v update-initramfs >/dev/null || refuse 'the initramfs is not built by initramfs-tools (package: initramfs-tools)' || return
    [[ -f $base/usr/share/plymouth/themes/impasto/impasto.plymouth && -f $base/etc/default/grub.d/impasto.cfg ]] \
        || refuse 'the theme is not installed (./setup system)' || return
    if (( DRY )); then
        say 'would choose the theme, add splash to the kernel command line and rebuild the initramfs with update-initramfs'
        return 0
    fi
    sudo -v
    if [[ $(plymouth-set-default-theme) != impasto ]]; then
        sudo plymouth-set-default-theme impasto || refuse 'the theme could not be chosen' || return
    fi
    say 'theme    impasto'
    if command -v update-grub >/dev/null; then
        sudo update-grub >/dev/null 2>&1 || say 'skipped  update-grub could not add splash'
    elif command -v grub-mkconfig >/dev/null; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
            || say 'skipped  grub-mkconfig could not add splash'
    fi
    sudo update-initramfs -u >/dev/null || refuse 'the initramfs did not rebuild' || return
    say 'rebuilt  the initramfs, with plymouth'
    stamp splash
    say 'ok · from the next boot'
}

ubuntu_uninstall_splash() {
    act sudo update-initramfs -u >/dev/null || say 'the initramfs did not rebuild: sudo update-initramfs -u'
    if command -v update-grub >/dev/null; then
        act sudo update-grub >/dev/null 2>&1 || true
    elif command -v grub-mkconfig >/dev/null && [[ -f /boot/grub/grub.cfg ]]; then
        act sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi
}
