# Ensure a current mkosi is used for builds
if [ ! -d "$DIRECTORY" ]; then
    git clone https://github.com/systemd/mkosi
else
    cd mkosi
    git pull
    cd ..
fi

# Add openSUSE repository for systemd dev, removing the need to compile systemd
curl -o "mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch.gpg" -fsSL https://download.opensuse.org/repositories/system:systemd/Arch/$(uname -m)/system_systemd_Arch.key
key=$(cat mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch.gpg)
fingerprint=$(gpg --quiet --with-colons --import-options show-only --import --fingerprint <<< "${key}" | awk -F: '$1 == "fpr" { print $10 }')
echo $fingerprint >> mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch-trusted

# Add these keys to the Skeleton
cp mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch.gpg mkosi.skeleton/usr/share/pacman/keyrings/system_systemd_Arch.gpg
cp mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch-trusted mkosi.skeleton/usr/share/pacman/keyrings/system_systemd_Arch-trusted
# Also add these keys to the final build
cp mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch.gpg mkosi.extra/usr/share/pacman/keyrings/system_systemd_Arch.gpg
cp mkosi.sandbox/usr/share/pacman/keyrings/system_systemd_Arch-trusted mkosi.extra/usr/share/pacman/keyrings/system_systemd_Arch-trusted

mkosi/bin/mkosi -d arch --profile server -f --debug -w