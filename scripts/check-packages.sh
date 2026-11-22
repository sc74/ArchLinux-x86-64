#!/bin/bash
# Which packages of packages.txt and packages-x86.txt can be installed on x86_64, from the
# official repos or from astromatto. Run in an archlinux container (make check-packages).
#   bash check-packages.sh /path/to/astroarch
set -u
SRC=${1:?path of the astroarch repository}

sed -i 's|\[core\]|[astromatto]\nSigLevel = Optional TrustAll\nServer = http://astroarch.astromatto.com:9000/$arch\n\n[core]|' /etc/pacman.conf
pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinux >/dev/null 2>&1
pacman -Sy --noconfirm >/dev/null || { echo "pacman -Sy failed"; exit 2; }

missing=0
for list in packages.txt packages-x86.txt; do
  [ -f "$SRC/$list" ] || { echo "(no $list)"; continue; }
  echo "== $list"
  while read -r pkg; do
    repo=$(pacman -Si "$pkg" 2>/dev/null | awk '/^Repository/ {print $3; exit}')
    if [ -n "$repo" ]; then
      printf 'ok       %-36s %s\n' "$pkg" "$repo"
    elif pacman -Sg "$pkg" 2>/dev/null | grep -q .; then
      printf 'ok       %-36s (group)\n' "$pkg"
    else
      # a name that only another package provides is not found by -Si
      prov=$(pacman -Ssq "^${pkg}$" 2>/dev/null | head -n1)
      printf 'MISSING  %-36s %s\n' "$pkg" "${prov:+(a package named like it: $prov)}"
      missing=$((missing + 1))
    fi
  done < <(grep -Ev '^\s*(#|$)' "$SRC/$list")
done
echo
echo "$missing package(s) not found for x86_64"
[ "$missing" -eq 0 ]
