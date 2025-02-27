#!/bin/bash
set -e
set -x
# linux-devel package creation (to generate headers etc needed to build kernel modules against)
arch=$ARCH
KDIR=$1
DEST=$2
KVER=$(cat $KDIR/include/config/kernel.release)
builddir="$DEST/lib/modules/$KVER/build"

echo "Creating Linux kernel header files from $KDIR into $builddir..."

cd $KDIR
echo "Installing build files..."
install -Dt "$builddir" -m644 .config Makefile Module.symvers System.map vmlinux
install -Dt "$builddir/kernel" -m644 kernel/Makefile
install -Dt "$builddir/arch/arm64" -m644 arch/arm64/Makefile
cp -t "$builddir" -a scripts

# required when STACK_VALIDATION is enabled
#install -Dt "$builddir/tools/objtool" tools/objtool/objtool

# required when DEBUG_INFO_BTF_MODULES is enabled
#install -Dt "$builddir/tools/bpf/resolve_btfids" tools/bpf/resolve_btfids/resolve_btfids

echo "Installing headers..."
cp -t "$builddir" -a include
cp -t "$builddir/arch/arm64" -a arch/arm64/include
install -Dt "$builddir/arch/arm64/kernel" -m644 arch/arm64/kernel/asm-offsets.s

# install headers for various subsystems
install -Dt "$builddir/drivers/md" -m644 drivers/md/*.h # software RAID
install -Dt "$builddir/net/mac80211" -m644 net/mac80211/*.h # wifi
#install -Dt "$builddir/drivers/media/i2c" -m644 drivers/media/i2c/msp3400-driver.h
#install -Dt "$builddir/drivers/media/usb/dvb-usb" -m644 drivers/media/usb/dvb-usb/*.h
#install -Dt "$builddir/drivers/media/dvb-frontends" -m644 drivers/media/dvb-frontends/*.h
#install -Dt "$builddir/drivers/media/tuners" -m644 drivers/media/tuners/*.h
#install -Dt "$builddir/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

echo "Installing KConfig files..."
find . -name 'Kconfig*' -exec install -Dm644 {} "$builddir/{}" \;

echo "Removing unneeded architectures..."
for arch in "$builddir"/arch/*/; do
  [[ $arch = */arm64/ ]] && continue
  echo "Removing $(basename "$arch")"
  rm -r "$arch"
done

echo "Removing documentation..."
rm -r "$builddir/Documentation"

echo "Removing broken symlinks..."
find -L "$builddir" -type l -printf 'Removing %P\n' -delete

echo "Removing loose objects..."
find "$builddir" -type f -name '*.o' -printf 'Removing %P\n' -delete

echo "Stripping build tools..."
while read -rd '' file; do
  case "$(file -Sib "$file")" in
    application/x-sharedlib\;*)      # Libraries (.so)
      strip -v $STRIP_SHARED "$file" ;;
    application/x-archive\;*)        # Libraries (.a)
      strip -v $STRIP_STATIC "$file" ;;
    application/x-executable\;*)     # Binaries
      strip -v $STRIP_BINARIES "$file" ;;
    application/x-pie-executable\;*) # Relocatable binaries
      strip -v $STRIP_SHARED "$file" ;;
  esac
done < <(find "$builddir" -type f -perm -u+x ! -name vmlinux -print0)


rm $builddir/vmlinux

if [ "$CROSS_COMPILE" ]; then
	# Required compilation steps
	echo "Cross-Compiling important build tools..."
	case "$KVER" in
	6.6*)
		echo "Building fixdep/modpost for 6.6..."
		(cd "$builddir/scripts/basic" && \
			${CROSS_COMPILE}gcc --static fixdep.c -o fixdep && \
			find . -type f -not -name fixdep -delete
		)
		(cd "$builddir/scripts/mod" && \
			${CROSS_COMPILE}gcc --static modpost.c sumversion.c file2alias.c -o modpost && \
			find . -type f -not -name modpost -delete
		)
		;;
	6.12*)
		echo "Building fixdep/modpost for 6.12..."
		(cd "$builddir/scripts/basic" && \
			${CROSS_COMPILE}gcc --static -I../include fixdep.c -o fixdep && \
			find . -type f -not -name fixdep -delete
		)
		(cd "$builddir/scripts/mod" && \
			${CROSS_COMPILE}gcc --static -I../include modpost.c sumversion.c file2alias.c symsearch.c -o modpost && \
			find . -type f -not -name modpost -delete
		)
		;;
	esac
fi

echo "Finished creating Linux-headers-gateworks"
